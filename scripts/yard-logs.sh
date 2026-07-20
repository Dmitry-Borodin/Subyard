#!/usr/bin/env bash
# yard-logs.sh — runtime logs of the yard (systemd journal inside the instance).
# Usage: yard-logs.sh [-f] [-n N] [unit]
#   -f       follow (stream) the log
#   -n N     show the last N lines (default 200)
#   unit     limit to one systemd unit (e.g. ssh, docker); default = whole journal
# This is the in-yard runtime log; the host-side audit log of `yard` invocations
# lives at $SUBYARD_HOME/logs/yard.log. Read-only; operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")

follow=0; lines=200; unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) follow=1 ;;
    -n) lines="${2:?-n needs a number}"; shift ;;
    -y | --yes) ;;  # handled by ui.sh (ASSUME_YES); ignore here
    -*) die "unknown option '$1'" ;;
    *)  unit="$1" ;;
  esac
  shift
done

incus_preflight
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it first ($(yard_cmd_hint) start)"

jargs=(journalctl -n "$lines")
[ -n "$unit" ] && jargs+=(-u "$unit")
if [ "$follow" = 1 ]; then
  jargs+=(-f)
else
  jargs+=(--no-pager)
fi
exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "${jargs[@]}"
