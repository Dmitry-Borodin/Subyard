#!/usr/bin/env bash
# network.sh — NetworkManager/UFW guard and yard bridge reachability stage.

[ -n "${SUBYARD_STAGE_NETWORK_SOURCED:-}" ] && return 0
SUBYARD_STAGE_NETWORK_SOURCED=1

stage_network_host_check() {
  reconcile_incus_reachable && power_host_safe "$INCUS_BRIDGE" || return 1
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    ufw_yard_rules_present "$INCUS_BRIDGE" || return 1
  fi
}

stage_network_check() {
  stage_network_host_check || return 1
  reconcile_power_stopped && return 0
  [ -n "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -c4 -fcsv 2>/dev/null)" ]
}

stage_network_plan() { printf 'Open host DHCP/DNS for the yard bridge (ufw; needs root)\n'; }
stage_network_apply() { "$SCRIPT_DIR/06-network.sh" --yes; }

stage_network_verify() {
  stage_network_host_check || return 1
  # This stage runs before first instance creation. Existing running yards additionally prove a lease.
  stage_instance_check || return 0
  reconcile_power_stopped && return 0
  [ -n "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -c4 -fcsv 2>/dev/null)" ]
}
