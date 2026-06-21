#!/usr/bin/env bash
# agent.sh — agent machines: a profile-configured Docker container INSIDE the yard
# for an imported project. Docker here is the yard's nested daemon, never the host's.
# Subcommands:
#   up      [path] [--profile NAME]   build/start the agent machine (idempotent)
#   shell   [path]                    interactive shell inside it
#   exec    [path] -- <cmd...>        run a command inside it
#   down    [path]                    stop it (keeps it)
#   destroy [path]                    remove it (workspace/caches in the yard stay)
#   list                              list agent machines in the yard
# The profile (config/profiles/<NAME>.env) supplies the base image, shared caches,
# env, and devices; toolchain install is a later, profile-specific slice.
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

yard_running() { [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; }
preflight() {
  command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard setup' first"
  yard_running || die "yard is not running — start it: yard up"
}

sub="${1:-}"; shift || true
[ -n "$sub" ] || die "need a subcommand: up | shell | exec | down | destroy | list"

# --- list: no project needed -------------------------------------------------
if [ "$sub" = list ]; then
  preflight
  echo "Agent machines in the yard:"
  ydocker ps -a --filter "label=subyard.agent=1" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null
  exit 0
fi

# --- parse: [path] [--profile NAME] [-- cmd...] ------------------------------
path="."; profile=""; cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:?--profile needs a name}"; shift ;;
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
preflight

case "$sub" in
  up)
    [ -n "$profile" ] || profile="$(state_get "$id" profile)"
    [ -n "$profile" ] || die "no profile — pass --profile <name> (have: $(cd "$PROFILES_DIR" && ls *.env 2>/dev/null | sed 's/\.env$//' | tr '\n' ' '))"
    pf="$PROFILES_DIR/$profile.env"
    [ -r "$pf" ] || die "no such profile: '$profile' ($pf)"
    # shellcheck disable=SC1090
    . "$pf"
    : "${BASE_IMAGE:?profile $profile has no BASE_IMAGE}"

    if ydocker inspect "$cname" >/dev/null 2>&1; then
      ydocker start "$cname" >/dev/null
      ok "agent '$name' already exists — started (profile $profile)"
      exit 0
    fi

    announce "yard agent up — $name (profile $profile)" \
      "Run a Docker container '$cname' inside the yard from image '$BASE_IMAGE'." \
      "Mount the project at /workspace, plus shared caches; export the profile env${DEVICES:+ and devices ($DEVICES)}." \
      "Pulls the image into the yard's Docker on first run."
    proceed_or_die

    # shared caches (persistent under the yard's /srv), owned by the dev uid
    for c in ${CACHES:-}; do yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$c"; done

    args=(run -d --name "$cname" --hostname "agent-${name}" --restart unless-stopped
          --label subyard.agent=1 --label "subyard.project=$id" --label "subyard.profile=$profile"
          -v "$yardPath:/workspace" -w /workspace)
    for c in ${CACHES:-}; do args+=(-v "$c:$c"); done
    # Inject every UPPER/lower env the profile declares, minus our control keys.
    while IFS= read -r k; do
      case "$k" in PROFILE_NAME|BASE_IMAGE|CACHES|DEVICES|OPTIONAL_FEATURES) continue ;; esac
      args+=(-e "$k=${!k}")
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)
    for d in ${DEVICES:-}; do
      case "$d" in
        kvm) yexec test -e /dev/kvm && args+=(--device /dev/kvm) || warn "/dev/kvm absent in yard — skipping" ;;
        *)   warn "profile device '$d' not understood — skipping" ;;
      esac
    done
    args+=("$BASE_IMAGE" sleep infinity)

    info "starting agent '$cname' …"
    ydocker "${args[@]}" >/dev/null || die "docker run failed in the yard"
    ok "agent '$name' up (profile $profile, image $BASE_IMAGE)"
    cat <<MSG

Next:
  ${PROG:-yard} agent shell $path          # shell inside the agent machine
  (toolchain install for '$profile' + emulator are the next slice)
MSG
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
      "The project workspace and shared caches in the yard are NOT touched."
    proceed_or_die
    ydocker rm -f "$cname" >/dev/null && ok "agent '$name' destroyed"
    ;;

  *)
    die "unknown subcommand '$sub' (expected: up | shell | exec | down | destroy | list)"
    ;;
esac
