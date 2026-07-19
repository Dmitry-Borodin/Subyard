#!/usr/bin/env bash
# yard-usage.sh — run the provisioned native ccusage binary inside the yard (as 'dev').
# ccusage reads each agent's native data there (~/.claude, ~/.codex, ~/.local/share/opencode), so the
# agents it understands are covered with no per-agent wiring. pi stores its own JSONL under
# ~/.pi/agent/sessions (persisted to the host store; ccusage may not parse it — see pi's /session).
# Arguments pass through unchanged.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROJ=(--project "$INCUS_PROJECT")

incus_preflight
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: $(yard_cmd_hint) start"

# Preserve argv through the dev login shell; printf '%q' needs a zero-argument guard.
args_q=""
[ "$#" -gt 0 ] && args_q="$(printf '%q ' "$@")"
repair_cmd="${SUBYARD_USAGE_REPAIR_HINT:-$(yard_cmd_hint) init}"
repair="yard usage: /usr/local/bin/ccusage is missing or not executable; repair with: $repair_cmd"
printf -v repair_q '%q' "$repair"
run="if [ ! -f /usr/local/bin/ccusage ] || [ -L /usr/local/bin/ccusage ] || [ ! -x /usr/local/bin/ccusage ]; then
       printf '%s\\n' $repair_q >&2; exit 1;
     fi
     exec /usr/local/bin/ccusage $args_q"

exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- su - "$DEV_USER" -c "$run"
