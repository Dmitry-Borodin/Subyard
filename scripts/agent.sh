#!/usr/bin/env bash
# agent.sh — agent machines: a profile-configured Docker container INSIDE the yard
# for an imported project. Docker here is the yard's nested daemon, never the host's.
# Subcommands:
#   up      [path] [--profile NAME] [--rebuild]   build/start the agent machine (idempotent)
#   info    [path]                    show what the profile exposes (visibility manifest)
#   shell   [path]                    interactive shell inside it
#   exec    [path] -- <cmd...>        run a command inside it
#   down    [path]                    stop it (keeps it)
#   destroy [path]                    remove it (workspace/caches in the yard stay)
#   list                              list agent machines in the yard
# The profile (config/profiles/<NAME>.conf) supplies the base image, shared caches,
# non-secret env, and devices. If it sets IMAGE_DOCKERFILE (a path inside the workspace),
# `up` builds that image in the yard's Docker and runs the agent from it (--rebuild forces);
# the Dockerfile is the project's, not Subyard's. Otherwise it runs BASE_IMAGE directly.
# An optional sibling <NAME>.env (gitignored, values host-only) carries secrets: it
# is staged into the yard and bind-mounted as a file at /run/subyard/profile.env
# (never -e), and never reaches the nested coding-sandbox tier.
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

yexec()   { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }
yexec_t() { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- "$@"; }
ydocker() { yexec docker "$@"; }
cname_for() { printf 'subyard-agent-%s' "$1"; }

# Profile keys that are control metadata for the consumer, not env to inject into
# the machine. Keep the -e injection and the manifest's envKeys in agreement.
is_control_key() {
  case "$1" in
    PROFILE_NAME|BASE_IMAGE|CACHES|DEVICES|OPTIONAL_FEATURES|IMAGE_DOCKERFILE|IMAGE_CONTEXT|IMAGE_TAG|\
    AGENT_MOUNTS|YARD_MOUNTS|YARD_CAPS|YARD_DEVICES)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Visibility manifest for an agent machine — declares what is available in THIS tier:
# the image it runs, feature flags, cache paths, exported env-var NAMES, secret slots
# (name + mount path, never values), devices. World-readable; no secret values. Reads
# up-scope vars ($profile, $pf, $BASE_IMAGE, $run_image, $have_secrets, $OPTIONAL_FEATURES,
# $CACHES, $DEVICES).
manifest_json() {
  local feats="" caches="" envkeys="" secs="" devs="" k
  for k in ${OPTIONAL_FEATURES:-}; do feats+="\"$k\","; done
  for k in ${CACHES:-};           do caches+="\"$k\","; done
  for k in ${DEVICES:-};          do devs+="\"$k\","; done
  while IFS= read -r k; do
    is_control_key "$k" && continue
    envkeys+="\"$k\","
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)
  [ "${have_secrets:-0}" = 1 ] && secs="{\"name\":\"profile.env\",\"path\":\"/run/subyard/profile.env\"}"
  cat <<JSON
{
  "profile": "$profile",
  "image": "${run_image:-$BASE_IMAGE}",
  "baseImage": "$BASE_IMAGE",
  "features": [${feats%,}],
  "caches": [${caches%,}],
  "envKeys": [${envkeys%,}],
  "secrets": [${secs}],
  "devices": [${devs%,}]
}
JSON
}

yard_running() { [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; }
preflight() {
  command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard setup' first"
  yard_running || die "yard is not running — start it: yard up"
}

sub="${1:-}"; shift || true
[ -n "$sub" ] || die "need a subcommand: up | info | shell | exec | down | destroy | list"

# --- list: no project needed -------------------------------------------------
if [ "$sub" = list ]; then
  preflight
  echo "Agent machines in the yard:"
  ydocker ps -a --filter "label=subyard.agent=1" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null
  exit 0
fi

# --- parse: [path] [--profile NAME] [--rebuild] [-- cmd...] ------------------
path="."; profile=""; rebuild=0; cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:?--profile needs a name}"; shift ;;
    --rebuild) rebuild=1 ;;
    --)        shift; cmd=("$@"); break ;;
    -y|--yes)  ;;  # handled by lib.sh
    -*)        die "unknown option '$1'" ;;
    *)         path="$1" ;;
  esac
  shift
done
[ -e "$path" ] || die "no such path: $path"

id="$(project_id "$path")"
state_exists "$id" || die "not imported: $(basename "$(realpath "$path")") — run: ${PROG:-yard} import $path"
name="$(state_get "$id" name)"
yardPath="$(state_get "$id" yardPath)"
cname="$(cname_for "$id")"
ysecret="/srv/agent-secrets/$id/profile.env"   # dev-owned, 0600, inside the yard
ymeta="/srv/agent-meta/$id/profile.json"       # dev-owned, 0644, no secret values
preflight

case "$sub" in
  up)
    [ -n "$profile" ] || profile="$(state_get "$id" profile)"
    [ -n "$profile" ] || die "no profile — pass --profile <name> (have: $(cd "$PROFILES_DIR" && ls *.conf 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' '))"
    pf="$PROFILES_DIR/$profile.conf"
    [ -r "$pf" ] || die "no such profile: '$profile' ($pf)"
    # Persist the chosen profile so later `agent up`/`yard setup` know it without --profile
    # (yard-extras reconcile enumerates projects and unions their profiles' YARD_* needs).
    state_set "$id" profile "$profile" 2>/dev/null || true
    # The .conf is the non-secret contract — safe to source (its keys are exported
    # below) and to log. The sibling .env may carry secrets, so it is NEVER sourced
    # here (that would leak its values into the -e injection); it is staged into the
    # yard and bind-mounted as a file instead.
    # shellcheck disable=SC1090
    . "$pf"
    : "${BASE_IMAGE:?profile $profile has no BASE_IMAGE}"
    sf="$PROFILES_DIR/$profile.env"; have_secrets=0
    [ -r "$sf" ] && have_secrets=1

    # environment image (Phase 4, variant 1): if the profile points at a Dockerfile
    # inside the workspace, build it in the yard's Docker and run the agent from it.
    # Source of truth is the project repo (pinned), not a copy in Subyard. Empty
    # IMAGE_DOCKERFILE => run BASE_IMAGE directly (previous behaviour).
    df="${IMAGE_DOCKERFILE:-}"; run_image="$BASE_IMAGE"; ctx=""
    if [ -n "$df" ]; then
      ctx="${IMAGE_CONTEXT:-$(dirname "$df")}"
      run_image="${IMAGE_TAG:-subyard-env-$id}"
    fi

    if ydocker inspect "$cname" >/dev/null 2>&1; then
      ydocker start "$cname" >/dev/null
      ok "agent '$name' already exists — started (profile $profile)"
      exit 0
    fi

    sec_line=(); build_line=()
    [ "$have_secrets" = 1 ] && sec_line=("Stage $profile.env secrets into the yard and mount them as a file at /run/subyard/profile.env (ro), never as -e.")
    [ -n "$df" ] && build_line=("Build the env image '$run_image' from the workspace's $df (context $ctx) in the yard's Docker.")
    announce "yard agent up — $name (profile $profile)" \
      ${build_line[@]+"${build_line[@]}"} \
      "Run a Docker container '$cname' inside the yard from image '$run_image'." \
      "Mount the project at /workspace, plus shared caches; export the profile's non-secret env${DEVICES:+ and devices ($DEVICES)}." \
      "Stage a visibility manifest (no secret values) at /run/subyard/profile.json (ro)." \
      ${sec_line[@]+"${sec_line[@]}"} \
      "Pulls/builds the image into the yard's Docker on first run."
    proceed_or_die

    # shared caches (persistent under the yard's /srv), owned by the dev uid
    for c in ${CACHES:-}; do yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$c"; done

    # build the env image from the workspace Dockerfile (idempotent; --rebuild forces)
    if [ -n "$df" ]; then
      yexec test -r "$yardPath/$df" \
        || die "profile wants '$df' in the workspace, but it's missing there — import/sync the project first"
      if [ "$rebuild" = 1 ] || ! ydocker image inspect "$run_image" >/dev/null 2>&1; then
        info "building env image '$run_image' from $df (context $ctx) …"
        ydocker build -t "$run_image" -f "$yardPath/$df" "$yardPath/$ctx" || die "env image build failed"
      else
        ok "env image '$run_image' already built (use --rebuild to force)"
      fi
    fi

    # secret-bearing env: stage as a dev-owned 0600 file inside the yard (not -e)
    if [ "$have_secrets" = 1 ]; then
      yexec install -d -m 0700 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ysecret")"
      incus file push "$sf" "$INSTANCE_NAME$ysecret" "${PROJ[@]}" \
        --mode 0600 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
        || die "could not stage $profile.env into the yard"
    fi

    # visibility manifest: stage a world-readable JSON (no secret values) the agent
    # can read to discover what is available in this tier (yard agent info).
    mfile="$(mktemp "${TMPDIR:-/tmp}/subyard-manifest.XXXXXX")"
    manifest_json > "$mfile"
    yexec install -d -m 0755 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ymeta")"
    incus file push "$mfile" "$INSTANCE_NAME$ymeta" "${PROJ[@]}" \
      --mode 0644 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
      || { rm -f "$mfile"; die "could not stage the manifest into the yard"; }
    rm -f "$mfile"

    args=(run -d --name "$cname" --hostname "agent-${name}" --restart unless-stopped
          --label subyard.agent=1 --label "subyard.project=$id" --label "subyard.profile=$profile"
          -v "$yardPath:/workspace" -w /workspace)
    for c in ${CACHES:-}; do args+=(-v "$c:$c"); done
    # AGENT_MOUNTS (Phase 4, layer C): extra binds ONLY in this project's machine,
    # not on the yard. Each entry is docker -v syntax: "<yard-src>:<ctr-dst>[:ro]".
    for m in ${AGENT_MOUNTS:-}; do args+=(-v "$m"); done
    args+=(-v "$ymeta:/run/subyard/profile.json:ro")
    [ "$have_secrets" = 1 ] && args+=(-v "$ysecret:/run/subyard/profile.env:ro")
    # Inject the profile's non-secret .conf keys as env, minus our control keys.
    # Secrets are never injected here — they arrive only via the file mount above.
    while IFS= read -r k; do
      is_control_key "$k" && continue
      args+=(-e "$k=${!k}")
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)
    for d in ${DEVICES:-}; do
      case "$d" in
        kvm) yexec test -e /dev/kvm && args+=(--device /dev/kvm) || warn "/dev/kvm absent in yard — skipping" ;;
        *)   warn "profile device '$d' not understood — skipping" ;;
      esac
    done
    args+=("$run_image" sleep infinity)

    info "starting agent '$cname' …"
    ydocker "${args[@]}" >/dev/null || die "docker run failed in the yard"
    ok "agent '$name' up (profile $profile, image $run_image)"
    # Level-1 requests (mounts/caps/devices the profile wants ON the yard) are applied
    # by the root-capable reconcile, not here (agent.sh stays no-root).
    if [ -n "${YARD_MOUNTS:-}${YARD_CAPS:-}${YARD_DEVICES:-}" ]; then
      warn "profile '$profile' requests yard-level extras (YARD_*). Apply with: ${PROG:-yard} setup"
    fi
    cat <<MSG

Next:
  ${PROG:-yard} agent shell $path          # shell inside the agent machine
  ${PROG:-yard} agent info  $path          # what the profile exposes in this machine
  (toolchain install for '$profile' + emulator are the next slice)
MSG
    ;;

  info)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no agent for '$name' — run: ${PROG:-yard} agent up $path --profile <name>"
    yexec test -r "$ymeta" || die "no manifest staged for '$name' — re-run: ${PROG:-yard} agent up $path"
    yexec cat "$ymeta"
    ;;

  shell)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no agent for '$name' — run: ${PROG:-yard} agent up $path --profile <name>"
    ydocker start "$cname" >/dev/null 2>&1 || true
    exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- docker exec -it "$cname" bash
    ;;

  exec)
    [ "${#cmd[@]}" -gt 0 ] || die "usage: ${PROG:-yard} agent exec $path -- <cmd...>"
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no agent for '$name' — run: ${PROG:-yard} agent up $path --profile <name>"
    ydocker start "$cname" >/dev/null 2>&1 || true
    exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- docker exec "$cname" "${cmd[@]}"
    ;;

  down)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no agent for '$name'"
    ydocker stop "$cname" >/dev/null && ok "agent '$name' stopped"
    ;;

  destroy)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no agent for '$name'"
    announce "yard agent destroy — $name" \
      "Remove the agent container '$cname' from the yard (force)." \
      "Drop staged profile secrets + manifest (/srv/agent-secrets/$id, /srv/agent-meta/$id); they re-stage on next up." \
      "The project workspace and shared caches in the yard are NOT touched."
    proceed_or_die
    ydocker rm -f "$cname" >/dev/null && ok "agent '$name' destroyed"
    yexec rm -rf "$(dirname "$ysecret")" "$(dirname "$ymeta")" 2>/dev/null || true
    ;;

  *)
    die "unknown subcommand '$sub' (expected: up | info | shell | exec | down | destroy | list)"
    ;;
esac
