#!/usr/bin/env bash
# project-env.sh — L2 project-env: a profile-configured Docker container INSIDE the yard
# for a project whose target is a profile (not `yard`). Docker here is the yard's nested
# daemon, never the host's. The box is the *environment*; the coding agent inside it is
# launched by the user, not by Subyard.
# Subcommands:
#   up      [path] [--rebuild]    build/start the box (idempotent)
#   info    [path]                show what the profile exposes (visibility manifest)
#   shell   [path]                interactive shell inside the box
#   exec    [path] -- <cmd...>    run a command inside the box
#   down    [path]                stop it (keeps it)
#   destroy [path]                remove it (workspace/caches in the yard stay)
#   list                          list project-env boxes in the yard
# The profile is the project's TARGET (state field `target`, set at sync/bind/clone):
# config/profiles/<target>/profile.conf supplies the base image, shared caches, non-secret
# env, and devices. If it sets IMAGE_DOCKERFILE (a path inside the workspace), `up` builds
# that image in the yard's Docker and runs the box from it (--rebuild forces); the Dockerfile
# is the project's own. Otherwise it runs BASE_IMAGE directly. An optional sibling profile.env
# (gitignored, host-only) carries secrets: it is staged into the yard and bind-mounted as a
# file at /run/subyard/profile.env (via the file mount, not -e).
# Remote yards (YARD_TYPE=remote): boxes need local incus + the yard's Docker, which live on
# the owner host — every subcommand refuses with a "run it there" hint (manage boxes via
# `ssh <dest> yard up …`).
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

yexec()   { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }
yexec_t() { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- "$@"; }
ydocker() { yexec docker "$@"; }
cname_for() { printf 'subyard-box-%s' "$1"; }

# Yard path of the host<->yard session store (host-agent-sessions mount, config/host.env).
SESSIONS_ROOT="/mnt/host/agent-sessions"

# Symlink the dev user's session dirs (HOST_LINKS) at the store mounted in the box, so the
# box's coding-agent sessions reach the shared store. Idempotent; mirrors scripts/04.
link_box_sessions() {
  local cname="$1" name target kind
  [ -n "${HOST_LINKS:-}" ] || return 0
  printf '%s\n' "$HOST_LINKS" | sed 's/[[:space:]]//g' | while IFS=: read -r name target kind; do
    [ -n "$name" ] && [ -n "$target" ] || continue
    [ "$kind" = file ] && continue   # single-writer files (db) are not shared into the box
    ydocker exec -u 0 "$cname" sh -c '
      name="$1"; target="$2"; uid="$3"
      home="$(getent passwd "$uid" | cut -d: -f6)"; home="${home:-/home/dev}"
      link="$home/$name"
      [ -d "$(dirname "$target")" ] || { echo "skip $name -> $target (session store not mounted)" >&2; exit 0; }
      install -d -o "$uid" -g "$uid" "$target" 2>/dev/null || true
      install -d -o "$uid" -g "$uid" "$(dirname "$link")" 2>/dev/null || true
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -sfn "$target" "$link"; chown -h "$uid:$uid" "$link"
      else
        echo "WARNING: $link exists and is not a symlink in the box — leaving it" >&2
      fi
    ' _ "$name" "$target" "$DEV_UID" || true
  done
}

# Profile keys that are control metadata for the consumer, not env to inject into
# the box. Keep the -e injection and the manifest's envKeys in agreement.
is_control_key() {
  case "$1" in
    PROFILE_NAME|BASE_IMAGE|CACHES|DEVICES|OPTIONAL_FEATURES|IMAGE_DOCKERFILE|IMAGE_CONTEXT|IMAGE_TAG|\
    ENV_MOUNTS|YARD_MOUNTS|YARD_CAPS|YARD_DEVICES)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Visibility manifest for a project-env box — declares what is available in THIS tier:
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
  incus_preflight
  yard_running || die "yard is not running — start it: ${PROG:-yard} start"
}

sub="${1:-}"; shift || true
[ -n "$sub" ] || die "need a subcommand: up | info | shell | exec | down | destroy | list"

# L2 project-env boxes need the yard's nested Docker + local incus — both live ON the owner
# host. A remote context cannot manage them from here, so refuse EVERY subcommand up front
# (before any resolution or incus) with a run-there hint.
if yard_is_remote; then
  die "L2 project-env boxes are managed on the yard's owner host — run there: ssh ${REMOTE_DEST:-<dest>} yard${REMOTE_YARD:+ -Y $REMOTE_YARD} $sub …"
fi

# --- list: no project needed -------------------------------------------------
if [ "$sub" = list ]; then
  preflight
  echo "Project-env boxes in the yard:"
  ydocker ps -a --filter "label=subyard.env=1" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null
  exit 0
fi

# --- parse: [path] [--rebuild] [-- cmd...] -----------------------------------
path="."; rebuild=0; cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1 ;;
    --)        shift; cmd=("$@"); break ;;
    -y|--yes)  ;;  # handled by lib.sh
    -*)        die "unknown option '$1'" ;;
    *)         path="$1" ;;
  esac
  shift
done
# Accept a path (default '.'), an exact id, or a project NAME. resolve_project_ctx resolves
# across yards and re-execs in the owning yard when the box lives elsewhere.
resolve_project_ctx "$path"
id="$RESOLVED_ID"
name="$(state_get "$id" name)"
yardPath="$(state_get "$id" yardPath)"
cname="$(cname_for "$id")"
ysecret="/srv/env-secrets/$id/profile.env"   # dev-owned, 0600, inside the yard
ymeta="/srv/env-meta/$id/profile.json"        # dev-owned, 0644, no secret values

# The project's target IS the profile for its L2 box. target=yard (or unset) => it runs in
# L1, there is no box — say so plainly for every subcommand.
target="$(state_get "$id" target)"
case "$target" in
  ""|yard) die "'$name' has target=${target:-yard} — it runs in L1 (the yard), there is no L2 box. Work in the yard ('${PROG:-yard} ssh' / '${PROG:-yard} code'), or re-add with --target <profile> to use a box." ;;
esac
profile="$target"
preflight

case "$sub" in
  up)
    pf="$PROFILES_DIR/$profile/profile.conf"
    [ -r "$pf" ] || die "project target '$profile' has no profile.conf at $pf"
    # profile.conf is the non-secret contract — safe to source (its keys are exported
    # below) and logged. The sibling profile.env may carry secrets: it is staged
    # into the yard and bind-mounted as a file (never sourced into -e).
    # shellcheck disable=SC1090
    . "$pf"
    : "${BASE_IMAGE:?profile $profile has no BASE_IMAGE}"
    sf="$PROFILES_DIR/$profile/profile.env"; have_secrets=0
    [ -r "$sf" ] && have_secrets=1

    # environment image (Phase 4, variant 1): if the profile points at a Dockerfile
    # inside the workspace, build it in the yard's Docker and run the box from it.
    # Source of truth is the project repo (pinned), not a copy in Subyard. Empty
    # IMAGE_DOCKERFILE => run BASE_IMAGE directly (previous behaviour).
    df="${IMAGE_DOCKERFILE:-}"; run_image="$BASE_IMAGE"; ctx=""
    if [ -n "$df" ]; then
      ctx="${IMAGE_CONTEXT:-$(dirname "$df")}"
      run_image="${IMAGE_TAG:-subyard-env-$id}"
    fi

    # Reject ENV_MOUNTS that would bind coding-agent credentials into the box (each box
    # keeps its own creds). Sessions are allowed — only creds are blocked.
    for m in ${ENV_MOUNTS:-}; do
      case "${m,,}" in
        *.claude/*|*.claude:*|*.codex/*|*.codex:*|*.pi/agent/*|*.pi/agent:*|*credentials*|*auth.json*)
          die "ENV_MOUNTS '$m' would share coding-agent credentials into the box; each project-env keeps its own credential store (sessions may be shared, creds never)" ;;
      esac
    done

    # Sessions share box -> yard (-> host): bind the yard's session store in if attached.
    share_sessions=0
    yexec test -d "$SESSIONS_ROOT" 2>/dev/null && share_sessions=1 || true

    if ydocker inspect "$cname" >/dev/null 2>&1; then
      ydocker start "$cname" >/dev/null
      [ "$share_sessions" = 1 ] && link_box_sessions "$cname"
      ok "box '$name' already exists — started (profile $profile)"
      exit 0
    fi

    sec_line=(); build_line=(); ses_line=()
    [ "$have_secrets" = 1 ] && sec_line=("Stage $profile/profile.env secrets into the yard and mount them as a file at /run/subyard/profile.env (ro), never as -e.")
    [ -n "$df" ] && build_line=("Build the env image '$run_image' from the workspace's $df (context $ctx) in the yard's Docker.")
    [ "$share_sessions" = 1 ] && ses_line=("Link the box's Claude/Codex session dirs at the yard's shared session store so usage flows box -> yard -> host; credentials stay local to this box.")
    announce "yard up — $name (project-env box, profile $profile)" \
      ${build_line[@]+"${build_line[@]}"} \
      "Run a Docker container '$cname' inside the yard from image '$run_image'." \
      "Mount the project at /workspace, plus shared caches; export the profile's non-secret env${DEVICES:+ and devices ($DEVICES)}." \
      "Stage a visibility manifest (no secret values) at /run/subyard/profile.json (ro)." \
      ${ses_line[@]+"${ses_line[@]}"} \
      ${sec_line[@]+"${sec_line[@]}"} \
      "Pulls/builds the image into the yard's Docker on first run."
    proceed_or_die y   # transient start (run the project-env box) — default Yes

    # shared caches (persistent under the yard's /srv), owned by the dev uid
    for c in ${CACHES:-}; do yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$c"; done

    # build the env image from the workspace Dockerfile (idempotent; --rebuild forces)
    if [ -n "$df" ]; then
      yexec test -r "$yardPath/$df" \
        || die "profile wants '$df' in the workspace, but it's missing there — sync (or bind) the project first"
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
        || die "could not stage $profile/profile.env into the yard"
    fi

    # visibility manifest: stage a world-readable JSON (no secret values) the box
    # can read to discover what is available in this tier (yard info).
    mfile="$(mktemp "${TMPDIR:-/tmp}/subyard-manifest.XXXXXX")"
    manifest_json > "$mfile"
    yexec install -d -m 0755 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ymeta")"
    incus file push "$mfile" "$INSTANCE_NAME$ymeta" "${PROJ[@]}" \
      --mode 0644 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
      || { rm -f "$mfile"; die "could not stage the manifest into the yard"; }
    rm -f "$mfile"

    args=(run -d --name "$cname" --hostname "box-${name}" --restart unless-stopped
          --label subyard.env=1 --label "subyard.project=$id" --label "subyard.profile=$profile"
          -v "$yardPath:/workspace" -w /workspace)
    for c in ${CACHES:-}; do args+=(-v "$c:$c"); done
    # ENV_MOUNTS (Phase 4, layer C): extra binds ONLY in this project's box, not on the
    # yard. Each entry is docker -v syntax: "<yard-src>:<ctr-dst>[:ro]".
    for m in ${ENV_MOUNTS:-}; do args+=(-v "$m"); done
    # Bind the session store (linked post-start by link_box_sessions); creds stay per-box.
    [ "$share_sessions" = 1 ] && args+=(-v "$SESSIONS_ROOT:$SESSIONS_ROOT:rw")
    args+=(-v "$ymeta:/run/subyard/profile.json:ro")
    [ "$have_secrets" = 1 ] && args+=(-v "$ysecret:/run/subyard/profile.env:ro")
    # Inject the profile's non-secret .conf keys as env, minus our control keys.
    # Secrets arrive via the file mount above (not -e).
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

    info "starting box '$cname' …"
    ydocker "${args[@]}" >/dev/null || die "docker run failed in the yard"
    [ "$share_sessions" = 1 ] && link_box_sessions "$cname"
    ok "box '$name' up (profile $profile, image $run_image)"
    # Level-1 requests (mounts/caps/devices the profile wants ON the yard) are applied
    # by the root-capable reconcile, not here (project-env.sh stays no-root).
    if [ -n "${YARD_MOUNTS:-}${YARD_CAPS:-}${YARD_DEVICES:-}" ]; then
      warn "profile '$profile' requests yard-level extras (YARD_*). Apply with: ${PROG:-yard} setup"
    fi
    cat <<MSG

Next:
  ${PROG:-yard} ssh  $path          # shell inside the box
  ${PROG:-yard} info $path          # what the profile exposes in this box
  ${PROG:-yard} code $path          # open the box in VS Code (Attach)
MSG
    ;;

  info)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name' — run: ${PROG:-yard} up $path"
    yexec test -r "$ymeta" || die "no manifest staged for '$name' — re-run: ${PROG:-yard} up $path"
    yexec cat "$ymeta"
    ;;

  shell)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name' — run: ${PROG:-yard} up $path"
    ydocker start "$cname" >/dev/null 2>&1 || true
    exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- docker exec -it "$cname" bash
    ;;

  exec)
    [ "${#cmd[@]}" -gt 0 ] || die "usage: ${PROG:-yard} ssh $path -- <cmd...>"
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name' — run: ${PROG:-yard} up $path"
    ydocker start "$cname" >/dev/null 2>&1 || true
    exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- docker exec "$cname" "${cmd[@]}"
    ;;

  down)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name'"
    # `|| die`, not a trailing `&&`: a genuine stop failure must surface (matching this file's
    # convention), not be swallowed into a silent non-zero exit as the case's last command.
    ydocker stop "$cname" >/dev/null || die "could not stop box '$name'"
    ok "box '$name' stopped"
    ;;

  destroy)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name'"
    announce "yard destroy box — $name" \
      "Remove the project-env box '$cname' from the yard (force)." \
      "Drop staged profile secrets + manifest (/srv/env-secrets/$id, /srv/env-meta/$id); they re-stage on next up." \
      "The project workspace and shared caches in the yard are NOT touched."
    proceed_or_die
    ydocker rm -f "$cname" >/dev/null && ok "box '$name' destroyed"
    yexec rm -rf "$(dirname "$ysecret")" "$(dirname "$ymeta")" 2>/dev/null || true
    ;;

  *)
    die "unknown subcommand '$sub' (expected: up | info | shell | exec | down | destroy | list)"
    ;;
esac
