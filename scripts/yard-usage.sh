#!/usr/bin/env bash
# yard-usage.sh — run ccusage inside the yard (as 'dev') to report coding-agent token usage.
# ccusage reads each agent's native data there (~/.claude, ~/.codex, ~/.local/share/opencode), so the
# agents it understands are covered with no per-agent wiring. pi stores its own JSONL under
# ~/.pi/agent/sessions (persisted to the host store; ccusage may not parse it — see pi's /session).
# Read-only; args pass through to ccusage (e.g. 'yard usage', 'yard usage daily', 'yard usage --json').
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
  || die "yard is not running — start it: ${PROG:-yard} start"

# Run ccusage in the yard as 'dev'. Prefer an installed binary; fall back to bunx/npx.
# (printf '%q' with zero args emits a quoted '' — guard the no-arg case.)
args_q=""
[ "$#" -gt 0 ] && args_q="$(printf '%q ' "$@")"
run="export npm_config_update_notifier=false;
     if command -v ccusage >/dev/null 2>&1; then set -- ccusage;
     elif command -v bunx >/dev/null 2>&1; then set -- bunx ccusage;
     elif command -v npx >/dev/null 2>&1; then set -- npx -y ccusage@latest;
     else echo 'yard usage: no ccusage/npx/bunx in the yard — provision a profile that installs Node (e.g. yard provision openclaw, which pre-installs ccusage), or install ccusage for the dev user' >&2; exit 127; fi
     exec \"\$@\" $args_q"

exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- su - "$DEV_USER" -c "$run"
