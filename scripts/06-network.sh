#!/usr/bin/env bash
# 06-network.sh — host networking safety for the yard. ALWAYS: keep NetworkManager off
# the Incus bridge + veth/tap devices (else NM DHCPs a yard veth and installs a rogue
# default route that BREAKS the host's internet). WHEN ufw is active: also open the
# bridge narrowly — DHCP (udp/67) + DNS (53) inbound + route in/out — since ufw's
# 'deny incoming' blocks the yard's dnsmasq and host Docker's FORWARD DROP blocks egress.
# No host services exposed. Root; idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# --- load config -------------------------------------------------------------
for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"

ufw_active=0
command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null && ufw_active=1

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
