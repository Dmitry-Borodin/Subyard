#!/usr/bin/env bash
# ssh.sh — owner-to-yard SSH proxy, config and authorized key stage.

[ -n "${SUBYARD_STAGE_SSH_SOURCED:-}" ] && return 0
SUBYARD_STAGE_SSH_SOURCED=1

stage_ssh_check() {
  reconcile_incus_reachable || return 1
  incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh || return 1
  [ "$(incus config device get "$INSTANCE_NAME" ssh type "${PROJ[@]}" 2>/dev/null || true)" = proxy ] \
    && [ "$(incus config device get "$INSTANCE_NAME" ssh listen "${PROJ[@]}" 2>/dev/null || true)" = "tcp:127.0.0.1:$SSH_PORT" ] \
    && [ "$(incus config device get "$INSTANCE_NAME" ssh connect "${PROJ[@]}" 2>/dev/null || true)" = tcp:127.0.0.1:22 ] \
    || return 1
  local snippet="$HOME/.ssh/subyard${YARD_NAME:+-$YARD_NAME}.config" config="$HOME/.ssh/config"
  [ -r "$snippet" ] && grep -qx "Host $SSH_HOST" "$snippet" && grep -qx "    Port $SSH_PORT" "$snippet" \
    || return 1
  grep -qx '    StrictHostKeyChecking yes' "$snippet" || return 1
  [ -r "$SUBYARD_HOME/ssh/known_hosts" ] \
    && ssh-keygen -F "[127.0.0.1]:$SSH_PORT" -f "$SUBYARD_HOME/ssh/known_hosts" >/dev/null \
    || return 1
  [ -r "$config" ] && grep -qxF "Include $(basename "$snippet")" "$config" || return 1
  if [ "${FORWARD_SSH_AGENT:-0}" = 1 ]; then
    grep -qx '    ForwardAgent yes' "$snippet" || return 1
  else
    ! grep -q '^[[:space:]]*ForwardAgent[[:space:]]\+yes' "$snippet" || return 1
  fi
  if reconcile_instance_running; then
    if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
      incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- \
        grep -q '^from="127[.]0[.]0[.]1,::1" ' \
          "/home/${DEV_USER:-dev}/.ssh/authorized_keys" >/dev/null 2>&1
    else
      incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -s "/home/${DEV_USER:-dev}/.ssh/authorized_keys" >/dev/null 2>&1
    fi
  else
    reconcile_power_stopped
  fi
}

stage_ssh_plan() { printf 'Set up SSH access into the yard (proxy + your key)\n'; }
stage_ssh_apply() { "$SCRIPT_DIR/07-ssh-access.sh" --yes; }
stage_ssh_verify() { stage_ssh_check; }
