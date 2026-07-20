#!/usr/bin/env bash
# provision.sh — core L1 packages, user, services, agents and ccusage stage.

[ -n "${SUBYARD_STAGE_PROVISION_SOURCED:-}" ] && return 0
SUBYARD_STAGE_PROVISION_SOURCED=1

stage_provision_agent_commands() {
  local agent provision_var command_var provision command
  for agent in ${AGENTS:-}; do
    provision_var="AGENT_${agent}_PROVISION"
    command_var="AGENT_${agent}_COMMAND"
    provision="${!provision_var:-}"
    [ -n "$provision" ] || continue
    [ -r "$provision" ] || return 1
    command="${!command_var:-}"
    [ -n "$command" ] || return 1
    case "$command" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    printf '%s\n' "$command"
  done
}

stage_provision_check() {
  reconcile_incus_reachable || return 1
  [ -n "${CCUSAGE_VERSION:-}" ] || return 1
  if reconcile_power_stopped; then
    [ "$(incus config get "$INSTANCE_NAME" user.subyard.ccusage_version "${PROJ[@]}" 2>/dev/null || true)" \
      = "${CCUSAGE_VERSION:-}" ]
    return
  fi
  local claude_req=0 codex_agents_req=0 agent_commands
  [ -n "${HOST_CLAUDE_MD:-}" ] && [ -f "$HOST_CLAUDE_MD" ] && claude_req=1
  [ -n "${HOST_CODEX_AGENTS_MD:-}" ] && [ -f "$HOST_CODEX_AGENTS_MD" ] && codex_agents_req=1
  agent_commands="$(stage_provision_agent_commands)" || return 1
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env DEV_USER="${DEV_USER:-dev}" --env DEV_SUDO="${DEV_SUDO:-0}" \
    --env CLAUDE_REQ="$claude_req" --env CODEX_AGENTS_REQ="$codex_agents_req" \
    --env HOST_LINKS="${HOST_LINKS:-}" --env AGENT_COMMANDS="$agent_commands" \
    --env CCUSAGE_VERSION="${CCUSAGE_VERSION:-}" \
    --env CCUSAGE_PATH="${CCUSAGE_INSTALL_PATH:-/usr/local/bin/ccusage}" \
    --env CCUSAGE_OWNER="${CCUSAGE_EXPECTED_OWNER:-0:0}" \
    -- sh -s >/dev/null 2>&1 <<'CHECK_PROVISION' || return 1
set -eu
command -v docker >/dev/null
for command in ${AGENT_COMMANDS:-}; do
  command_path="$(command -v "$command")"
  [ -x "$command_path" ]
done
id "$DEV_USER" >/dev/null
case "${CCUSAGE_VERSION:-}" in
  '' | latest) exit 1 ;;
esac
[ -f "$CCUSAGE_PATH" ] && [ ! -L "$CCUSAGE_PATH" ] && [ -x "$CCUSAGE_PATH" ]
[ "$(stat -c '%a' "$CCUSAGE_PATH")" = 755 ]
[ "$(stat -c '%u:%g' "$CCUSAGE_PATH")" = "$CCUSAGE_OWNER" ]
[ "$(LC_ALL=C od -An -tx1 -N4 "$CCUSAGE_PATH" | tr -d '[:space:]')" = 7f454c46 ]
[ "$("$CCUSAGE_PATH" --version 2>/dev/null)" = "ccusage $CCUSAGE_VERSION" ]
home="$(getent passwd "$DEV_USER" | cut -d: -f6)"; home="${home:-/home/$DEV_USER}"
if [ "${CLAUDE_REQ:-0}" = 1 ]; then [ -f "$home/.claude/CLAUDE.md" ]; fi
if [ "${CODEX_AGENTS_REQ:-0}" = 1 ]; then [ -f "$home/.codex/AGENTS.md" ]; fi
sudoers="/etc/sudoers.d/90-subyard-$DEV_USER"
if [ "${DEV_SUDO:-0}" = 1 ]; then [ -f "$sudoers" ]; else [ ! -f "$sudoers" ]; fi
drift=0
for entry in $(printf '%s\n' "${HOST_LINKS:-}" | sed 's/[[:space:]]//g'); do
  name="${entry%%:*}"; rest="${entry#*:}"; target="${rest%%:*}"
  { [ -n "$name" ] && [ -n "$target" ]; } || continue
  mount_root="/$(printf '%s' "$target" | cut -d/ -f2-4)"
  [ -d "$mount_root" ] || continue
  { [ -e "$home/$name" ] || [ -L "$home/$name" ]; } || drift=1
done
legacy="$home/.local/share/opencode/storage"
if [ -L "$legacy" ] && [ "$(readlink "$legacy")" = /mnt/host/agent-sessions/opencode/storage ]; then
  exit 1
fi
[ "$drift" = 0 ]
CHECK_PROVISION
  [ "$(incus config get "$INSTANCE_NAME" user.subyard.ccusage_version "${PROJ[@]}" 2>/dev/null || true)" \
    = "${CCUSAGE_VERSION:-}" ]
}

stage_provision_plan() { printf 'Provision the yard (packages, Docker, user, services)\n'; }
stage_provision_apply() { "$SCRIPT_DIR/04-provision-subyard.sh" --yes; }
stage_provision_verify() { stage_provision_check; }

# Profiles with an explicit in-yard provision adapter; used by init's opt-in post-stage offer.
stage_provision_profiles() {
  local state_dir="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}" file profile
  {
    for profile in ${YARD_PROFILES:-}; do
      [ -r "$SCRIPT_DIR/../config/profiles/$profile/provision.sh" ] && printf '%s\n' "$profile"
    done
    if command -v jq >/dev/null 2>&1 && [ -d "$state_dir" ]; then
      for file in "$state_dir"/*.json; do
        [ -e "$file" ] || continue
        profile="$(jq -r '.profile // ""' "$file" 2>/dev/null)"
        [ -n "$profile" ] || continue
        [ -r "$SCRIPT_DIR/../config/profiles/$profile/provision.sh" ] && printf '%s\n' "$profile"
      done
    fi
  } | sort -u || true
}
