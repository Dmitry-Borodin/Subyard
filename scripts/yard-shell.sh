#!/usr/bin/env bash
# yard-shell.sh — open a ROOT shell in the yard (or run a root command) via incus exec.
# For an unprivileged 'dev' shell over SSH use `yard ssh`; for an L2 project-env box use
# `yard ssh <project>`. Usage: yard shell [-- cmd...]   (no cmd → interactive root bash)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")

cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --)       shift; cmd=("$@"); break ;;
    -y|--yes) ;;
    -*)       die "unknown option '$1'" ;;
    *)        cmd+=("$1") ;;
  esac
  shift
done

incus_preflight
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: $(yard_cmd_hint) start"

if [ "${#cmd[@]}" -gt 0 ]; then
  exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "${cmd[@]}"
fi
exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -t -- bash
