#!/usr/bin/env bash
# agent-configs.sh — refresh global agent instructions and default configs in an existing yard.
# Used by `yard init --configs` and the full Phase 3 provision. Does not install packages, rebuild
# the instance, touch credentials/session stores, or change host networking.
# Usage: yard init --configs [-y]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
PROJ=(--project "$INCUS_PROJECT")

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run '${PROG:-yard} init' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: ${PROG:-yard} start"

announce_confirm "Refresh agent instructions and configs in $INSTANCE_NAME" \
  "Overwrite the in-yard copies of global Claude/Codex instructions when their host sources exist." \
  "Overwrite enabled agents' default config/rules from the current Subyard templates." \
  "Keep agent credentials, sessions, projects, packages, services, and host networking unchanged."

echo "Agent instructions:"
if [ -n "${HOST_CLAUDE_MD:-}" ] && [ -f "$HOST_CLAUDE_MD" ]; then
  incus file push "$HOST_CLAUDE_MD" \
    "$INSTANCE_NAME/home/$DEV_USER/.claude/CLAUDE.md" "${PROJ[@]}" \
    --create-dirs --uid "$DEV_UID" --gid "$DEV_UID" --mode 0644
  ok "copied $HOST_CLAUDE_MD -> ~$DEV_USER/.claude/CLAUDE.md"
else
  ok "no HOST_CLAUDE_MD file to copy — skipping"
fi
if [ -n "${HOST_CODEX_AGENTS_MD:-}" ] && [ -f "$HOST_CODEX_AGENTS_MD" ]; then
  incus file push "$HOST_CODEX_AGENTS_MD" \
    "$INSTANCE_NAME/home/$DEV_USER/.codex/AGENTS.md" "${PROJ[@]}" \
    --create-dirs --uid "$DEV_UID" --gid "$DEV_UID" --mode 0644
  ok "copied $HOST_CODEX_AGENTS_MD -> ~$DEV_USER/.codex/AGENTS.md"
else
  ok "no HOST_CODEX_AGENTS_MD file to copy — skipping"
fi

echo "Agent configs:"
for _agent in ${AGENTS:-}; do
  _did=0
  for _kind in CONFIG RULES; do
    _src_var="AGENT_${_agent}_${_kind}"; _dst_var="AGENT_${_agent}_${_kind}_DEST"
    _src="${!_src_var:-}"; _dst="${!_dst_var:-}"
    if [ -z "$_src" ] || [ -z "$_dst" ]; then continue; fi
    if [ -f "$_src" ]; then
      incus file push "$_src" \
        "$INSTANCE_NAME/home/$DEV_USER/$_dst" "${PROJ[@]}" \
        --create-dirs --uid "$DEV_UID" --gid "$DEV_UID" --mode 0644
      ok "$_agent: copied $(basename "$_src") -> ~$DEV_USER/$_dst"; _did=1
    else
      warn "$_agent: $_kind source $_src missing — skipping"
    fi
  done
  [ "$_did" = 0 ] && ok "$_agent: no default config — skipping"
done
unset _agent _kind _src_var _dst_var _src _dst _did

ok "Agent instructions and configs refreshed. Restart active agent sessions to load them."
