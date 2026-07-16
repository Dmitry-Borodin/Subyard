#!/usr/bin/env bash
# yard-shell.sh — open a dev shell in the yard, optionally at a project's directory.
# Usage: yard shell [--root] [path|name|id] [-- cmd...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"

root=0 selector='' cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) cat <<EOF
Usage: ${PROG:-yard} shell [--root] [path|name|id] [-- command...]

Open a shell as $DEV_USER (default), optionally in a registered project's directory.
Use --root for a root shell. A command must follow a standalone --.
EOF
      exit 0 ;;
    --)       shift; cmd=("$@"); break ;;
    --root)   root=1 ;;
    -y|--yes) ;;
    -*)       die "unknown option '$1'" ;;
    *)        [ -z "$selector" ] || die "only one project may be selected; put commands after '--'"
              selector="$1" ;;
  esac
  shift
done

cwd="/home/$DEV_USER"
if [ -n "$selector" ]; then
  maybe_reconcile "$selector"
  resolve_project_ctx "$selector"
  cwd="$(state_get "$RESOLVED_ID" yardPath)"
  [ -n "$cwd" ] || die "project '$selector' has no yard path"
fi

incus_preflight
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: $(yard_cmd_hint) start"

user_args=(--user "$DEV_UID" --group "$DEV_GID" --env "HOME=/home/$DEV_USER")
if [ "$root" = 1 ]; then
  user_args=(--user 0 --group 0 --env HOME=/root)
fi

if [ "${#cmd[@]}" -gt 0 ]; then
  exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" "${user_args[@]}" --cwd "$cwd" -- "${cmd[@]}"
fi
exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" "${user_args[@]}" --cwd "$cwd" -t -- bash -l
