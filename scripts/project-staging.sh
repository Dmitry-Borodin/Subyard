#!/usr/bin/env bash
# project-staging.sh — SHARED staging zone(s) for a live gateway (OpenClaw), inside the yard,
# isolated from production. A staging zone is identified by a ZONE NAME (default `canonical`),
# NOT by a dev project — it is a shared service: dev-agents work in their own L2 boxes
# (project-env.sh) and USE the zone; they do not each run their own gateway with the one test
# bot. This is the O3 two-tier design (decisions-glossary "Staging design v2", 2026-06-27):
#   * canonical — persistent, built from `master`, baseline/smoke/demo, never accrues dirty state;
#   * ephemeral — a run of an agent's UNCOMMITTED worktree (test without committing). MVP = a LIVE BIND
#     of the worktree ('up --source'); reflink-snapshot isolation is deferred (P4). Serialized behind
#     canonical via a lease on the bot identity.
#
# Hard invariant — NOTHING here may touch production:
#   * a STAGING-only data root /srv/staging/<zone> (its own VASILY_HOME / state), never prod;
#   * STAGING-only credentials, mounted into the runner only (ro file / persistent creds vol),
#     never via -e, never under /srv/cache;
#   * a startup prod-fingerprint GUARD (ours; the project has no such check) that refuses to
#     start unless the config is marked staging AND the bot token's fingerprint is not on the
#     operator's prod denylist (config/prod-fingerprints), plus state-root markers.
#   * the bot identity is the scarce resource: a flock+file LEASE (FIFO/TTL/epoch) admits one
#     poller at a time; handover is fence-by-lifecycle (stop the prior holder's gateway).
#
# Subcommands (a leading [zone] defaults to `canonical`):
#   up      [zone] [--rebuild] [--source PATH]   build/start the runner box (gateway stays down);
#                               --source PATH live-binds a worktree as /workspace (run uncommitted, no commit)
#   start   [zone]               prod-guard + acquire lease, then launch the gateway
#   stop    [zone]               stop the gateway + release the lease (keeps the box)
#   status  [zone]               box + gateway + lease + staging-fingerprint overview
#   logs    [zone] [-f]          tail the gateway log
#   shell   [zone]               interactive shell inside the runner box
#   down    [zone]               stop the box (keeps it + its staging data root)
#   destroy [zone] [--purge]     remove the box (--purge also wipes the staging data root)
#   list                         list staging-runner boxes in the yard
#   e2e     [path]               (Slice 2) reflink-isolated ephemeral run — DEFERRED to P4; for now use
#                               'up <zone> --source <agent-workspace>' for a live-bind run of uncommitted code
#
# Per-zone config (optional): config/staging/<zone>.conf — non-secret knobs (PROFILE, SOURCE_BIND,
# GATEWAY_CMD, BOT_LEASE_KEY, LEASE_TTL). See config/staging/canonical.conf.example.
# Operator-owned; no root. Docker here is the yard's nested daemon, never the host's.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-service.sh
. "$SCRIPT_DIR/lib-service.sh"   # profile shared-resource helpers: yexec, svc_require_yard_running

DEV_UID="${DEV_UID:-1000}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
ZONES_DIR="$SCRIPT_DIR/../config/staging"
PROD_FP_FILE="$SCRIPT_DIR/../config/prod-fingerprints"   # host-only sha256 denylist (no secrets)
LEASE_DIR="/srv/staging/_lease"                          # in the yard; one lease per bot identity

ydocker() { yexec docker "$@"; }
cname_for() { printf 'subyard-staging-%s' "$1"; }

sub="${1:-}"; shift || true
[ -n "$sub" ] || die "need a subcommand: up | start | stop | status | logs | shell | down | destroy | list | e2e"

# --- list / e2e: handled before zone resolution ------------------------------
if [ "$sub" = list ]; then
  svc_require_yard_running
  echo "Staging-runner zones in the yard:"
  ydocker ps -a --filter "label=subyard.staging=1" \
    --format 'table {{.Label "subyard.zone"}}\t{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null
  exit 0
fi
if [ "$sub" = e2e ]; then
  # Slice 2 — ephemeral lane. Implemented next; fail loudly rather than pretend.
  cat >&2 <<'EOF'
  [fail] `yard staging e2e` (reflink-isolated ephemeral lane) is DEFERRED to P4 (full isolation).
         For now run an agent's UNCOMMITTED code via a LIVE BIND (the MVP, no commit needed):
           yard staging up <zone> --source /srv/workspaces/<agent-id>
           yard staging start <zone>
         Live bind = the worktree is shared into the runner as-is; edits propagate into the
         running stage by design (no snapshot). reflink snapshot / per-run isolation / teardown
         land in p4-staging-full-isolation.
EOF
  exit 2
fi

# --- is-up: silent registry probe (yard status) — any zone with a live gateway pid? -----------
# Handled before zone resolution + the loud yard-running check: it must stay quiet and just
# return 0/1. "up" = any staging-runner box (any zone) has a live gateway pid (the box bind-mounts
# its data root at the same path, so the pid is /srv/staging/<zone>/run/gateway.pid).
if [ "$sub" = is-up ]; then
  incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 || exit 1
  if yexec sh -c '
        for c in $(docker ps -q --filter "label=subyard.staging=1" 2>/dev/null); do
          z="$(docker inspect -f "{{ index .Config.Labels \"subyard.zone\" }}" "$c" 2>/dev/null)"
          [ -n "$z" ] || continue
          p="/srv/staging/$z/run/gateway.pid"
          docker exec "$c" sh -c "[ -f \"$p\" ] && kill -0 \"\$(cat \"$p\")\" 2>/dev/null" && exit 0
        done
        exit 1' 2>/dev/null
  then exit 0; else exit 1; fi
fi

# --- parse: [zone] [--rebuild|--purge|-f] ------------------------------------
zone="canonical"; rebuild=0; purge=0; follow=0; zone_set=0; src_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1 ;;
    --source)  src_override="${2:-}"; [ -n "$src_override" ] || die "--source needs a yard path"; shift ;;
    --purge)   purge=1 ;;
    -f|--follow) follow=1 ;;
    -y|--yes)  ;;  # handled by lib.sh
    -*)        die "unknown option '$1'" ;;
    *)         [ "$zone_set" = 1 ] && die "unexpected extra argument '$1'"; zone="$1"; zone_set=1 ;;
  esac
  shift
done
case "$zone" in *[!a-zA-Z0-9_-]*) die "zone name '$zone' must be [a-zA-Z0-9_-]" ;; esac

svc_require_yard_running

# zone config (non-secret knobs) + defaults
PROFILE=openclaw
SOURCE_BIND=""                              # optional: a yard path to bind as the source tree
GATEWAY_CMD="scripts/vasily gateway run"
BUILD_CMD=""                                # optional: rebuild cmd run in the runner (cwd /workspace)
                                            #   before the gateway launches, so 'restart' picks up live edits
BOT_LEASE_KEY=bot                           # lease key = bot identity (shared across zones)
LEASE_TTL=45
CREDS_DEST=""                               # optional: path INSIDE the runner for a persistent creds store
                                            #   (a one-time manual provider login survives box recreate);
                                            #   backed by $dataRoot/creds. Empty => creds live under VASILY_HOME.
zconf="$ZONES_DIR/$zone.conf"
# shellcheck disable=SC1090
[ -r "$zconf" ] && . "$zconf"
[ -n "$src_override" ] && SOURCE_BIND="$src_override"   # --source overrides the zone-conf bind (live-bind a worktree)

profile="$PROFILE"
pf="$PROFILES_DIR/$profile/profile.conf"
[ -r "$pf" ] || die "zone '$zone' profile '$profile' has no profile.conf at $pf"

cname="$(cname_for "$zone")"
dataRoot="/srv/staging/$zone"
srcDir="$dataRoot/src"                       # /workspace inside the box
vasilyHome="$dataRoot/vasily"                # VASILY_HOME => staging-only state
ylog="$dataRoot/logs/gateway.log"
GW_PID="$dataRoot/run/gateway.pid"
HB_PID="$dataRoot/run/heartbeat.pid"
ysecret="/srv/env-secrets/staging-$zone/staging.env"
BOX_SECRET="/run/subyard/staging.env"

box_exists()  { ydocker inspect "$cname" >/dev/null 2>&1; }
require_box() { box_exists || die "no staging-runner for zone '$zone' — run: ${PROG:-yard} staging up $zone"; }
gateway_running() {
  ydocker exec "$cname" sh -c '[ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null' _ "$GW_PID" 2>/dev/null
}

# --- bot-identity lease (flock + file; FIFO/TTL/epoch; single host) -----------
# Runs in the yard as dev. mode=normal refuses a live foreign holder (PREEMPT if we may take
# it: ephemeral over canonical); mode=force overwrites (after the caller stopped the holder).
# Echoes "OK <epoch>" / "PREEMPT <holder>" / "BUSY <holder> <kind> <secs>".
lease_acquire() {
  local kind="$1" mode="${2:-normal}"
  yexec sh -s -- "$LEASE_DIR" "$BOT_LEASE_KEY" "$zone" "$kind" "$LEASE_TTL" "$mode" <<'LEASE'
set -eu
dir="$1"; key="$2"; me="$3"; kind="$4"; ttl="$5"; mode="$6"
install -d -m 0755 "$dir"
lock="$dir/$key.lock"; st="$dir/$key.json"
exec 9>"$lock"; flock 9
now=$(date +%s)
holder=""; hk=""; epoch=0; exp=0
if [ -r "$st" ]; then
  holder=$(jq -r '.holder // ""' "$st"); hk=$(jq -r '.kind // ""' "$st")
  epoch=$(jq -r '.epoch // 0' "$st");    exp=$(jq -r '.expires // 0' "$st")
fi
if [ "$mode" != force ] && [ -n "$holder" ] && [ "$holder" != "$me" ] && [ "$now" -lt "$exp" ]; then
  if [ "$kind" = ephemeral ] && [ "$hk" = canonical ]; then echo "PREEMPT $holder"; exit 0; fi
  echo "BUSY $holder $hk $((exp-now))"; exit 0
fi
epoch=$((epoch+1))
printf '{"holder":"%s","kind":"%s","epoch":%d,"expires":%d}\n' "$me" "$kind" "$epoch" "$((now+ttl))" >"$st"
echo "OK $epoch"
LEASE
}
lease_release() {
  yexec sh -s -- "$LEASE_DIR" "$BOT_LEASE_KEY" "$zone" <<'LEASE'
set -eu
dir="$1"; key="$2"; me="$3"
st="$dir/$key.json"; lock="$dir/$key.lock"
[ -r "$st" ] || exit 0
exec 9>"$lock"; flock 9
[ "$(jq -r '.holder // ""' "$st")" = "$me" ] || exit 0
rm -f "$st"
LEASE
}
lease_show() { yexec sh -c '[ -r "$1/$2.json" ] && cat "$1/$2.json" || echo "{}"' _ "$LEASE_DIR" "$BOT_LEASE_KEY" 2>/dev/null; }

case "$sub" in
  up)
    # shellcheck disable=SC1090
    . "$pf"
    : "${BASE_IMAGE:?profile $profile has no BASE_IMAGE}"
    df="${IMAGE_DOCKERFILE:-}"; run_image="$BASE_IMAGE"; ctx=""
    if [ -n "$df" ]; then ctx="${IMAGE_CONTEXT:-$(dirname "$df")}"; run_image="${IMAGE_TAG:-subyard-staging-$zone}"; fi

    sf="$ZONES_DIR/$zone.env"; have_secrets=0
    [ -r "$sf" ] && have_secrets=1

    # live-bind worktree (if any) must exist in the yard (run an agent's uncommitted code)
    [ -z "$SOURCE_BIND" ] || yexec test -d "$SOURCE_BIND" \
      || die "SOURCE_BIND '$SOURCE_BIND' is not a directory in the yard — point it at an agent's workspace (e.g. /srv/workspaces/<id>)"

    if box_exists; then
      ydocker start "$cname" >/dev/null
      # keep the in-yard CLI fresh (zone.env/run-args were written on first up)
      incus file push "$SCRIPT_DIR/sy-stage.sh" "$INSTANCE_NAME/usr/local/bin/sy-stage" "${PROJ[@]}" --mode 0755 --uid 0 --gid 0 >/dev/null 2>&1 || true
      ok "staging-runner zone '$zone' already exists — started (gateway down; '${PROG:-yard} staging start $zone' or in-yard 'sy-stage restart $zone')"
      exit 0
    fi

    # source tree: a bound yard path, else the zone's own src dir (operator populates from main)
    src_desc="$srcDir (populate from main: clone/sync into it)"
    [ -n "$SOURCE_BIND" ] && src_desc="$SOURCE_BIND (bound)"
    sec_line=(); build_line=()
    [ "$have_secrets" = 1 ] && sec_line=("Stage staging/$zone.env into the yard and mount it ro at $BOX_SECRET (never -e).")
    [ -n "$df" ] && build_line=("Build the env image '$run_image' from $df (context $ctx) in the yard's Docker.")
    announce "yard staging up — zone '$zone' (shared staging-runner, profile $profile)" \
      ${build_line[@]+"${build_line[@]}"} \
      "Run a Docker container '$cname' inside the yard from image '$run_image' (role: staging-runner, zone $zone)." \
      "Create a STAGING-only data root at $dataRoot (its own VASILY_HOME; never prod state)." \
      "Source tree at /workspace <- $src_desc." \
      ${sec_line[@]+"${sec_line[@]}"} \
      "The gateway is NOT started here — 'yard staging start $zone' runs the prod-guard + lease first."
    proceed_or_die

    for d in "$dataRoot" "$dataRoot/logs" "$dataRoot/run" "$dataRoot/creds" "$vasilyHome" "$srcDir" "$LEASE_DIR"; do
      yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$d"
    done

    if [ -n "$df" ]; then
      src_for_build="${SOURCE_BIND:-$srcDir}"
      yexec test -r "$src_for_build/$df" \
        || die "zone wants '$df' in the source tree, but it's missing under $src_for_build — populate the source first (clone main / set SOURCE_BIND)"
      if [ "$rebuild" = 1 ] || ! ydocker image inspect "$run_image" >/dev/null 2>&1; then
        info "building env image '$run_image' from $df (context $ctx) …"
        ydocker build -t "$run_image" -f "$src_for_build/$df" "$src_for_build/$ctx" || die "env image build failed"
      else
        ok "env image '$run_image' already built (use --rebuild to force)"
      fi
    fi

    if [ "$have_secrets" = 1 ]; then
      yexec install -d -m 0700 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ysecret")"
      incus file push "$sf" "$INSTANCE_NAME$ysecret" "${PROJ[@]}" \
        --mode 0600 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
        || die "could not stage staging/$zone.env into the yard"
    fi

    src_mount="${SOURCE_BIND:-$srcDir}"
    # mid = the STABLE run spec (everything bar the swappable source bind, the name/hostname and
    # the image/cmd). Reused verbatim by the in-yard 'sy-stage rebind' (written to run-args below).
    mid=(--restart unless-stopped
         --label subyard.staging=1 --label "subyard.zone=$zone" --label "subyard.profile=$profile"
         -v "$dataRoot:$dataRoot"
         -v "$LEASE_DIR:$LEASE_DIR"
         -e "VASILY_HOME=$vasilyHome"
         -e "SUBYARD_STAGING_ZONE=$zone"
         -e "SUBYARD_STAGING_DATA_ROOT=$dataRoot")
    for c in ${CACHES:-}; do yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$c"; mid+=(-v "$c:$c"); done
    [ "$have_secrets" = 1 ] && mid+=(-v "$ysecret:$BOX_SECRET:ro")
    # persistent creds store (a one-time manual provider login survives box recreate); backed by $dataRoot/creds
    [ -n "$CREDS_DEST" ] && mid+=(-v "$dataRoot/creds:$CREDS_DEST")
    while IFS= read -r k; do
      case "$k" in
        PROFILE_NAME|BASE_IMAGE|CACHES|DEVICES|OPTIONAL_FEATURES|IMAGE_DOCKERFILE|IMAGE_CONTEXT|IMAGE_TAG|\
        ENV_MOUNTS|YARD_MOUNTS|YARD_CAPS|YARD_DEVICES) continue ;;
      esac
      mid+=(-e "$k=${!k}")
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)

    info "starting staging-runner zone '$zone' …"
    ydocker run -d --name "$cname" --hostname "staging-${zone}" \
      -v "$src_mount:/workspace" -w /workspace \
      "${mid[@]}" "$run_image" sleep infinity >/dev/null || die "docker run failed in the yard"
    ok "staging-runner zone '$zone' up (profile $profile, image $run_image)"

    # --- in-yard self-serve control plane (sy-stage): let the agent reserve+run from the yard ----
    gw_cmd_eff="${STAGING_GATEWAY_CMD:-$GATEWAY_CMD}"
    # zone.env — the self-contained spec the in-yard 'sy-stage' consumes (no host config in the yard).
    yexec sh -c 'cat > "$1"' _ "$dataRoot/zone.env" <<ZENV
CNAME='$cname'
DATA_ROOT='$dataRoot'
RUN_IMAGE='$run_image'
GATEWAY_CMD='$gw_cmd_eff'
BUILD_CMD='$BUILD_CMD'
BOT_LEASE_KEY='$BOT_LEASE_KEY'
LEASE_TTL='$LEASE_TTL'
CREDS_DEST='$CREDS_DEST'
SOURCE_BIND='$src_mount'
GW_PID='$GW_PID'
HB_PID='$HB_PID'
YLOG='$ylog'
ZENV
    # run-args — the reusable mid spec for 'sy-stage rebind' (one arg per line, preserves spaces).
    printf '%s\n' "${mid[@]}" | yexec sh -c 'cat > "$1"' _ "$dataRoot/run-args"
    # prod-fingerprints — the in-yard prod-guard reads this (deny-by-default stays effective).
    [ -r "$PROD_FP_FILE" ] && incus file push "$PROD_FP_FILE" "$INSTANCE_NAME$dataRoot/prod-fingerprints" "${PROJ[@]}" --mode 0644 >/dev/null 2>&1 || true
    # install the in-yard CLI on the agent's PATH.
    if incus file push "$SCRIPT_DIR/sy-stage.sh" "$INSTANCE_NAME/usr/local/bin/sy-stage" "${PROJ[@]}" --mode 0755 --uid 0 --gid 0 >/dev/null 2>&1; then
      ok "in-yard self-serve ready: in the yard the agent runs 'sy-stage restart $zone' (reserve/restart/rebind/stop/status/logs)"
    else
      warn "could not install sy-stage into the yard — in-yard self-serve unavailable (operator-only via 'yard staging')"
    fi
    cat <<MSG

Next:
  1. Source tree at /workspace <- $src_desc.
       live-bind an agent's uncommitted worktree: ${PROG:-yard} staging up $zone --source /srv/workspaces/<id>
       (or set SOURCE_BIND in config/staging/$zone.conf); else populate $srcDir from \`master\`.
  2. Paste STAGING creds into the runner (one-time):
       ${PROG:-yard} staging shell $zone
       # set channels.telegram.tokenFile/botToken in \$VASILY_HOME/openclaw/openclaw.json,
       # mark it staging ("_subyardStaging": true), log in the staging model provider (Codex) once.
       # To survive box recreate, set CREDS_DEST in $zone.conf to the runner's creds dir
       # (persisted at $dataRoot/creds); else the login lives in the box until 'destroy'.
  3. Record PROD bot fingerprint(s) so the guard refuses them:
       printf '%s' "<PROD_BOT_TOKEN>" | sha256sum   # hash only
       echo "<that-hash>" >> config/prod-fingerprints
  4. ${PROG:-yard} staging start $zone
MSG
    ;;

  start)
    require_box
    if gateway_running; then ok "gateway already running for zone '$zone'"; exit 0; fi

    # --- prod-fingerprint GUARD (deny-by-default) ----------------------------
    prod_fps=""
    [ -r "$PROD_FP_FILE" ] && prod_fps="$(grep -vE '^\s*(#|$)' "$PROD_FP_FILE" 2>/dev/null | tr -s '[:space:]' '\n' || true)"
    guard_out="$(ydocker exec -i -e "SUBYARD_PROD_FPS=$prod_fps" "$cname" sh -s <<'GUARD'
set -eu
cfg="${OPENCLAW_CONFIG_PATH:-$VASILY_HOME/openclaw/openclaw.json}"
[ -r "$cfg" ] || { echo "FAIL no staging config at $cfg — paste it first (yard staging shell)"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq absent in the runner — cannot validate config"; exit 1; }

# explicit staging marker (config or staging.env), else refuse
marker=0
[ "$(jq -r '._subyardStaging // false' "$cfg" 2>/dev/null)" = true ] && marker=1
[ -r /run/subyard/staging.env ] && grep -qE '^SUBYARD_STAGING=1\b' /run/subyard/staging.env && marker=1
[ "$marker" = 1 ] || { echo "FAIL config not marked staging (\"_subyardStaging\": true, or SUBYARD_STAGING=1 in staging.env)"; exit 1; }

# state-root must live under the staging data root, never under a prod path
sroot="${OPENCLAW_STATE_DIR:-$VASILY_HOME/openclaw}"
case "$sroot" in
  "$SUBYARD_STAGING_DATA_ROOT"/*) : ;;
  *) echo "FAIL state dir $sroot is not under the staging data root $SUBYARD_STAGING_DATA_ROOT"; exit 1 ;;
esac

# resolve the bot token (tokenFile preferred), fingerprint it, refuse prod
tf="$(jq -r '.channels.telegram.tokenFile // ""' "$cfg" 2>/dev/null || true)"
if [ -n "$tf" ] && [ -r "$tf" ]; then tok="$(cat "$tf")"; else tok="$(jq -r '.channels.telegram.botToken // ""' "$cfg" 2>/dev/null || true)"; fi
[ -n "$tok" ] || { echo "FAIL no telegram bot token in $cfg (channels.telegram.botToken/tokenFile)"; exit 1; }
fp="$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)"
for bad in ${SUBYARD_PROD_FPS:-}; do
  [ "$fp" = "$bad" ] && { echo "FAIL bot-token fingerprint matches a recorded PROD fingerprint — refusing"; exit 1; }
done
echo "OK staging marker + state-root ok; bot fp ${fp%${fp#????????}}… not on prod denylist"
GUARD
)" || true
    # Fail closed: only an explicit "OK …" verdict may proceed. Empty/garbage (e.g. stdin
    # never reached the runner) must refuse, never silently pass the guard.
    case "$guard_out" in
      OK\ *)   ok "prod-guard: ${guard_out#OK }" ;;
      FAIL\ *) die "prod-guard refused start: ${guard_out#FAIL }" ;;
      *)       die "prod-guard produced no verdict — refusing (fail-closed): '${guard_out:-<empty>}'" ;;
    esac
    [ -n "$prod_fps" ] || warn "config/prod-fingerprints empty — guard passed on the staging marker alone; record prod hashes to harden it"

    # --- acquire the bot lease (canonical takes it too, so ephemeral can preempt) ---
    la="$(lease_acquire canonical normal)"
    case "$la" in
      OK\ *)   epoch="${la#OK }"; ok "lease acquired (epoch $epoch)";;
      BUSY\ *) die "bot lease held: ${la#BUSY } — another runner is polling; stop it or wait";;
      *)       die "could not acquire bot lease: $la";;
    esac

    gw_cmd="${STAGING_GATEWAY_CMD:-$GATEWAY_CMD}"
    announce "yard staging start — zone '$zone'" \
      "Prod-guard passed, lease held (epoch $epoch). Launch the gateway: '$gw_cmd' (cwd /workspace)." \
      "Log -> $ylog ; pid -> $GW_PID. A heartbeat renews the lease while it runs."
    proceed_or_die
    ydocker exec -d "$cname" sh -c '
      cd /workspace || exit 1
      mkdir -p "$(dirname "$2")"
      setsid sh -c "$1" >>"$2" 2>&1 &
      echo $! >"$3"
    ' _ "$gw_cmd" "$ylog" "$GW_PID"
    sleep 1
    if ! gateway_running; then lease_release || true; die "gateway exited immediately — check: ${PROG:-yard} staging logs $zone"; fi
    # heartbeat sidecar — runs INSIDE the box (tied to box lifetime, not this CLI process); it
    # renews the lease (flock on the bind-mounted lease file) while the gateway pid is alive,
    # then releases. The lease dir is mounted at the same path, so the same inode is locked.
    ydocker exec -d "$cname" sh -c '
      lease="$1/$2.json"; lock="$1/$2.lock"; me="$3"; ttl="$4"; gwpid="$5"; hbpid="$6"
      echo $$ >"$hbpid"
      step=$((ttl/3)); [ "$step" -gt 0 ] || step=5
      while [ -f "$gwpid" ] && kill -0 "$(cat "$gwpid" 2>/dev/null)" 2>/dev/null; do
        ( exec 9>"$lock"; flock 9
          [ -r "$lease" ] && [ "$(jq -r ".holder//\"\"" "$lease")" = "$me" ] || exit 0
          now=$(date +%s); t="$lease.t.$$"
          jq --argjson e "$((now+ttl))" ".expires=\$e" "$lease" >"$t" && mv "$t" "$lease"
        ) 2>/dev/null || true
        sleep "$step"
      done
      ( exec 9>"$lock"; flock 9
        [ -r "$lease" ] && [ "$(jq -r ".holder//\"\"" "$lease")" = "$me" ] && rm -f "$lease"
      ) 2>/dev/null || true
      rm -f "$hbpid"
    ' _ "$LEASE_DIR" "$BOT_LEASE_KEY" "$zone" "$LEASE_TTL" "$GW_PID" "$HB_PID"
    ok "gateway started for zone '$zone' (pid $(ydocker exec "$cname" cat "$GW_PID" 2>/dev/null))"
    info "follow it: ${PROG:-yard} staging logs $zone -f"
    ;;

  stop)
    require_box
    if gateway_running; then
      ydocker exec "$cname" sh -c '
        pid="$(cat "$1" 2>/dev/null)"; [ -n "$pid" ] || exit 0
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$1"
      ' _ "$GW_PID"
      ok "gateway stopped for zone '$zone'"
    else
      ok "gateway not running for zone '$zone'"
    fi
    lease_release >/dev/null 2>&1 || true
    ;;

  status)
    if ! box_exists; then echo "zone '$zone': (no runner) — ${PROG:-yard} staging up $zone"; exit 0; fi
    echo "zone:    $zone (profile $profile)"
    echo "box:     $cname ($(ydocker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null))"
    echo "data:    $dataRoot (VASILY_HOME=$vasilyHome)"
    if gateway_running; then echo "gateway: running (pid $(ydocker exec "$cname" cat "$GW_PID" 2>/dev/null))"; else echo "gateway: down"; fi
    echo "lease:   $(lease_show)"
    ydocker exec "$cname" sh -c '
      cfg="${OPENCLAW_CONFIG_PATH:-$VASILY_HOME/openclaw/openclaw.json}"
      command -v jq >/dev/null 2>&1 || { echo "config:  (jq absent)"; exit 0; }
      [ -r "$cfg" ] || { echo "config:  (none at $cfg)"; exit 0; }
      tf="$(jq -r ".channels.telegram.tokenFile // \"\"" "$cfg" 2>/dev/null)"
      if [ -n "$tf" ] && [ -r "$tf" ]; then tok="$(cat "$tf")"; else tok="$(jq -r ".channels.telegram.botToken // \"\"" "$cfg" 2>/dev/null)"; fi
      mk="$(jq -r "._subyardStaging // false" "$cfg" 2>/dev/null)"
      if [ -n "$tok" ]; then fp="$(printf "%s" "$tok" | sha256sum | cut -d" " -f1); echo "config:  staging-marker=$mk bot-fp=${fp%${fp#????????}}…"; else echo "config:  staging-marker=$mk (no bot token set)"; fi
    ' 2>/dev/null || true
    ;;

  logs)
    require_box
    if [ "$follow" = 1 ]; then
      exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- docker exec "$cname" tail -n 200 -f "$ylog"
    fi
    ydocker exec "$cname" sh -c '[ -r "$1" ] && tail -n 200 "$1" || echo "(no gateway log yet at $1)"' _ "$ylog"
    ;;

  shell)
    require_box
    ydocker start "$cname" >/dev/null 2>&1 || true
    exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- docker exec -it "$cname" bash
    ;;

  down)
    require_box
    gateway_running && warn "gateway still running — stopping the box stops it too"
    lease_release >/dev/null 2>&1 || true
    ydocker stop "$cname" >/dev/null && ok "staging-runner zone '$zone' stopped"
    ;;

  destroy)
    require_box
    purge_line=("The staging data root $dataRoot is KEPT (use --purge to wipe it).")
    [ "$purge" = 1 ] && purge_line=("WIPE the staging data root $dataRoot (state, config, creds, logs) — irreversible.")
    announce "yard staging destroy — zone '$zone'" \
      "Remove the staging-runner box '$cname' from the yard (force)." \
      "Release the bot lease if held; drop staged secrets under /srv/env-secrets/staging-$zone." \
      "${purge_line[@]}"
    proceed_or_die
    lease_release >/dev/null 2>&1 || true
    ydocker rm -f "$cname" >/dev/null && ok "staging-runner zone '$zone' destroyed"
    yexec rm -rf "$(dirname "$ysecret")" 2>/dev/null || true
    [ "$purge" = 1 ] && yexec rm -rf "$dataRoot" 2>/dev/null && ok "staging data root wiped"
    ;;

  *)
    die "unknown subcommand '$sub' (expected: up | start | stop | status | logs | shell | down | destroy | list | e2e)"
    ;;
esac
