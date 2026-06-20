#!/usr/bin/env bash
# yard-logs.sh — runtime logs of the yard (systemd journal inside the instance).
# Usage: yard-logs.sh [-f] [-n N] [unit]
#   -f       follow (stream) the log
#   -n N     show the last N lines (default 200)
#   unit     limit to one systemd unit (e.g. ssh, docker); default = whole journal
# This is the in-yard runtime log; the host-side audit log of `yard` invocations
# lives at $SUBYARD_HOME/logs/yard.log. Read-only; operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")

follow=0; lines=200; unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) follow=1 ;;
    -n) lines="${2:?-n needs a number}"; shift ;;
    -y | --yes) ;;  # handled by lib.sh (ASSUME_YES); ignore here
    -*) die "unknown option '$1'" ;;
    *)  unit="$1" ;;
  esac
  shift
done

command -v incus >/dev/null 2>&1 || die "incus not found — run setup first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it first (yard up)"

jargs=(journalctl -n "$lines")
[ -n "$unit" ] && jargs+=(-u "$unit")
if [ "$follow" = 1 ]; then
  jargs+=(-f)
else
  jargs+=(--no-pager)
fi
exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "${jargs[@]}"
