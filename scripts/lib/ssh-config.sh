#!/usr/bin/env bash
# ssh-config.sh — atomic operator-owned OpenSSH config updates.

[ -n "${SUBYARD_SSH_CONFIG_SOURCED:-}" ] && return 0
SUBYARD_SSH_CONFIG_SOURCED=1

ssh_config_prepend_once() {
  local config="${1:?ssh_config_prepend_once needs a config path}"
  local line="${2:?ssh_config_prepend_once needs a line}"
  local directory temp

  directory="$(dirname "$config")"
  [ -e "$config" ] || : > "$config"
  grep -qxF "$line" "$config" 2>/dev/null && return 0

  # A fixed config.tmp may be stale or root-owned after an interrupted legacy sudo run. A fresh
  # same-directory file avoids that collision and still gives us an atomic rename.
  temp="$(mktemp "$directory/.subyard-ssh-config.XXXXXX")" || return 1
  if ! { printf '%s\n' "$line"; cat "$config"; } > "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if ! chmod 0600 "$temp" || ! mv -f -- "$temp" "$config"; then
    rm -f -- "$temp"
    return 1
  fi
}
