#!/usr/bin/env bash
# host.sh — explicit host/system adapters and fail-closed guards.

[ -n "${SUBYARD_HOST_SOURCED:-}" ] && return 0
SUBYARD_HOST_SOURCED=1

require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  local why="${1:-it changes the host system}"
  if command -v sudo >/dev/null 2>&1; then
    warn "this needs root: $why"
    info "re-running under sudo (you'll be asked for your password)…"
    exec sudo -- env SUBYARD_ELEVATED=1 \
      ${SUBYARD_YARD:+SUBYARD_YARD="$SUBYARD_YARD"} \
      ${SUBYARD_YARD_EXPLICIT:+SUBYARD_YARD_EXPLICIT="$SUBYARD_YARD_EXPLICIT"} \
      "$SUBYARD_SCRIPT_PATH" ${SUBYARD_SCRIPT_ARGV[@]+"${SUBYARD_SCRIPT_ARGV[@]}"}
  fi
  printf '\n%sNeeds root and sudo is not installed — run as root:%s\n    %s%s %s%s\n\n' \
    "$C_WARN" "$C_OFF" "$C_HEAD" "$SUBYARD_SCRIPT_PATH" "${SUBYARD_SCRIPT_ARGV[*]:-}" "$C_OFF" >&2
  exit 1
}

incus_preflight() {
  command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard init' first"
  incus info >/dev/null 2>&1 && return 0
  if id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; then
    warn "can't reach the Incus daemon: this session predates your 'incus-admin' group (the yard is fine)."
    printf "  Log out and back in once to fix it everywhere, or run %snewgrp incus-admin%s for this shell.\n" \
      "$C_HEAD" "$C_OFF" >&2
    exit 1
  fi
  die "can't reach Incus — you're not in the 'incus-admin' group, or the daemon isn't running. Run 'yard init' first."
}

nm_unmanaged_guard() {
  local bridge="${1:-incusbr0}" conf="${2:-/etc/NetworkManager/conf.d/zz-subyard-unmanaged.conf}"
  local want changed=0 nm_rc
  if power_nm_active; then :; else
    nm_rc=$?
    if [ "$nm_rc" -eq 1 ]; then ok "NetworkManager not active — no route-hijack guard needed"; return 0; fi
    die "$POWER_ERROR"
  fi
  install -d -m 0755 "$(dirname "$conf")"
  rm -f "$(dirname "$conf")/99-subyard-unmanaged.conf" 2>/dev/null
  local spec="type:veth;driver:veth;interface-name:veth*;interface-name:$bridge;interface-name:docker*;interface-name:br-*;interface-name:virbr*;interface-name:vnet*;interface-name:tap*;interface-name:macvtap*"
  local mspec="type:veth,driver:veth,interface-name:veth*,interface-name:$bridge,interface-name:docker*,interface-name:br-*,interface-name:virbr*,interface-name:vnet*,interface-name:tap*,interface-name:macvtap*"
  want="[main]
no-auto-default=$spec

[keyfile]
unmanaged-devices=$spec

[device-subyard]
match-device=$mspec
managed=0"
  if [ ! -f "$conf" ] || ! printf '%s\n' "$want" | cmp -s - "$conf"; then
    printf '%s\n' "$want" > "$conf"
    changed=1
  fi
  chmod 0644 "$conf"
  systemctl reload NetworkManager 2>/dev/null \
    || { command -v nmcli >/dev/null 2>&1 && nmcli general reload 2>/dev/null; } \
    || die "could not reload NetworkManager after updating $conf"
  if [ "$changed" = 1 ]; then
    ok "NetworkManager set to ignore $bridge + veth/tap/docker/virbr ($conf)"
  else
    ok "NetworkManager already ignoring $bridge + veth/tap/docker/virbr"
  fi
  power_nm_guard_effective "$bridge" || die "$POWER_ERROR (check: sudo NetworkManager --print-config)"
  ok "verified: NM effective config protects $bridge and veth devices"
}

ufw_yard_rules_present() {
  local bridge="${1:?ufw_yard_rules_present needs a bridge}"
  local rules="${SUBYARD_UFW_RULES_FILE:-/etc/ufw/user.rules}"
  [ -r "$rules" ] || return 1
  awk -v bridge="$bridge" '
    $1 == "###" && $2 == "tuple" && $3 == "###" {
      action = $4; dport = $6; iface = $10
      if (action == "allow" && dport == "67" && iface == "in_" bridge) dhcp = 1
      if (action == "allow" && dport == "53" && iface == "in_" bridge) dns = 1
      if (action == "route:allow" && iface == "in_" bridge) route_in = 1
      if (action == "route:allow" && iface == "out_" bridge) route_out = 1
    }
    END { exit !(dhcp && dns && route_in && route_out) }
  ' "$rules"
}

ufw_rules_set_probe_access() {
  local mode="${1:?ufw_rules_set_probe_access needs enable or disable}"
  local rules="${SUBYARD_UFW_RULES_FILE:-/etc/ufw/user.rules}" group
  [ -e "$rules" ] || return 1
  case "$mode" in
    enable) group=incus-admin; getent group "$group" >/dev/null 2>&1 || return 1 ;;
    disable) group=root ;;
    *) return 2 ;;
  esac
  chgrp "$group" "$rules" && chmod 0640 "$rules"
}

zabbly_suite() {
  command -v apt-get >/dev/null 2>&1 || return 1
  [ -r /etc/os-release ] || return 1
  local suite
  suite="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  [ -n "$suite" ] || return 1
  printf '%s\n' "$suite"
}

add_zabbly_lts_repo() {
  local key=/etc/apt/keyrings/zabbly.asc
  local source=/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources
  local suite arch want
  suite="$(zabbly_suite)" || { warn "no apt codename in /etc/os-release — can't add the Zabbly repo"; return 1; }
  command -v curl >/dev/null 2>&1 || { warn "curl not found — can't fetch the Zabbly signing key"; return 1; }
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -s "$key" ]; then
    curl -fsSL https://pkgs.zabbly.com/key.asc -o "$key" \
      || { warn "failed to download the Zabbly signing key"; return 1; }
    chmod 0644 "$key"
    ok "installed Zabbly signing key ($key)"
  else
    ok "Zabbly signing key already present"
  fi
  want="Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-6.0
Suites: $suite
Components: main
Architectures: $arch
Signed-By: $key"
  if [ ! -f "$source" ] || ! printf '%s\n' "$want" | cmp -s - "$source"; then
    printf '%s\n' "$want" > "$source"
    ok "added Zabbly LTS-6.0 apt source ($source; suite=$suite)"
  else
    ok "Zabbly LTS-6.0 apt source already present (suite=$suite)"
  fi
  info "apt-get update (Zabbly)"
  apt-get update -qq || { warn "apt-get update failed after adding the Zabbly repo"; return 1; }
}
