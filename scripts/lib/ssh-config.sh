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

ssh_known_host_replace() {
  local known_hosts="${1:?ssh_known_host_replace needs a file}"
  local endpoint="${2:?ssh_known_host_replace needs an endpoint}"
  local public_key="${3:?ssh_known_host_replace needs a public key}"
  local directory temp type blob _rest

  read -r type blob _rest <<<"$public_key"
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  directory="$(dirname "$known_hosts")"
  install -d -m 0700 "$directory" || return 1
  temp="$(mktemp "$directory/.subyard-known-hosts.XXXXXX")" || return 1
  if [ -e "$known_hosts" ]; then
    cp -- "$known_hosts" "$temp" || { rm -f -- "$temp"; return 1; }
  fi
  ssh-keygen -R "$endpoint" -f "$temp" >/dev/null 2>&1 \
    || { rm -f -- "$temp" "$temp.old"; return 1; }
  rm -f -- "$temp.old"
  printf '%s %s %s\n' "$endpoint" "$type" "$blob" >> "$temp" \
    || { rm -f -- "$temp"; return 1; }
  chmod 0600 "$temp" && mv -f -- "$temp" "$known_hosts" \
    || { rm -f -- "$temp"; return 1; }
}
