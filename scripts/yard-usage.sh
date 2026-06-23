#!/usr/bin/env bash
# yard-usage.sh — run ccusage inside the yard (as 'dev') to report coding-agent token usage.
# ccusage reads each agent's native data there (~/.claude, ~/.codex, ~/.local/share/opencode),
# so all agents are covered with no per-agent wiring. Read-only; args pass through to ccusage
# (e.g. 'yard usage', 'yard usage daily', 'yard usage --json').
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROJ=(--project "$INCUS_PROJECT")

command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard init' first"
incus info >/dev/null 2>&1 \
  || die "can't reach the Incus daemon — run 'yard init', or retry in a fresh 'incus-admin' session"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: ${PROG:-yard} start"

# Run ccusage in the yard as 'dev'. Prefer an installed binary; fall back to bunx/npx.
# (printf '%q' with zero args emits a quoted '' — guard the no-arg case.)
args_q=""
[ "$#" -gt 0 ] && args_q="$(printf '%q ' "$@")"
run="if command -v ccusage >/dev/null 2>&1; then set -- ccusage;
     elif command -v bunx >/dev/null 2>&1; then set -- bunx ccusage;
     elif command -v npx >/dev/null 2>&1; then set -- npx -y ccusage@latest;
     else echo 'yard usage: need ccusage (or bun/npx) in the yard — install ccusage for the dev user' >&2; exit 127; fi
     exec \"\$@\" $args_q"

exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- su - "$DEV_USER" -c "$run"
