#!/usr/bin/env bash
# 06-network.sh — host networking safety for the yard. ALWAYS: keep NetworkManager off
# the Incus bridge + veth/tap devices (else NM DHCPs a yard veth and installs a rogue
# default route that BREAKS the host's internet). WHEN ufw is active: also open the
# bridge narrowly — DHCP (udp/67) + DNS (53) inbound + route in/out — since ufw's
# 'deny incoming' blocks the yard's dnsmasq and host Docker's FORWARD DROP blocks egress.
# No host services exposed. Root; idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
mode=apply
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --verify) mode=verify ;;
  esac
done

ufw_active=0
command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null && ufw_active=1

if [ "$mode" != apply ]; then
  command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1 || exit 1
  power_host_safe "$BRIDGE" || exit 1
  [ "$ufw_active" = 0 ] || ufw_yard_rules_present "$BRIDGE" || exit 1
  instance_exists=0
  incus info "$INSTANCE_NAME" --project "$INCUS_PROJECT" >/dev/null 2>&1 && instance_exists=1
  [ "$mode" != verify ] || [ "$instance_exists" = 1 ] || exit 0
  [ "$instance_exists" = 1 ] || exit 1
  instance_state="$(power_state "$INCUS_PROJECT" "$INSTANCE_NAME")"
  [ "$instance_state" != STOPPED ] || [ "${SUBYARD_POWER_DESIRED:-}" != stopped ] || exit 0
  [ "$instance_state" = RUNNING ] || exit 1
  [ -n "$(incus list "$INSTANCE_NAME" --project "$INCUS_PROJECT" -c4 -fcsv 2>/dev/null)" ]
  exit
fi

ann=("Keep NetworkManager off '$BRIDGE' + veth*/tap* — prevents a rogue DHCP default route that breaks host internet.")
title="Subyard — host networking guard ($BRIDGE)"
why="the NetworkManager guard writes a host config file"
if [ "$ufw_active" = 1 ]; then
  title="Subyard — host networking guard + ufw rules ($BRIDGE)"
  why="the NetworkManager guard + ufw rules change host networking"
  ann+=("ufw is active: also open '$BRIDGE' inbound DHCP (udp/67) + DNS (53) and route in/out, so the yard has network.")
  ann+=("Interface-scoped; no IPs/subnets; no host services exposed.")
else
  ann+=("ufw is not active — only the NetworkManager guard is applied.")
fi
announce "$title" "${ann[@]}"
proceed_or_die
require_root "$why"

# Always: stop NetworkManager hijacking the host's internet via a yard veth.
echo "NetworkManager guard:"
nm_unmanaged_guard "$BRIDGE"

if [ "$ufw_active" = 1 ]; then
  echo "ufw rules for $BRIDGE (idempotent — re-adds print 'Skipping adding existing rule'):"
  ufw allow in on "$BRIDGE" to any port 67 proto udp
  ufw allow in on "$BRIDGE" to any port 53
  ufw route allow in on "$BRIDGE"
  ufw route allow out on "$BRIDGE"
  # UFW is root-only and its rule files default to 0640 root:root. incus-admin is already
  # root-equivalent; grant it read-only access so future init plans can prove convergence
  # without prompting for sudo or trusting a separate "done" marker.
  ufw_rules_set_probe_access enable \
    || die "could not make UFW rule state readable by incus-admin"
  ufw_yard_rules_present "$BRIDGE" \
    || die "UFW rules for '$BRIDGE' did not match the required DHCP/DNS/route policy after apply"
  ok "verified persisted UFW rules for $BRIDGE"
else
  ok "ufw inactive — Incus manages the bridge firewall; skipped ufw rules"
fi

echo
ok "Host networking done."
cat <<MSG

Verify:
  ip route show default          # only your real gateway — no veth default route
  incus exec yard --project subyard -- curl -4 -sS --max-time 8 -o /dev/null -w 'egress http=%{http_code}\n' https://deb.debian.org/
MSG
