#!/usr/bin/env bash
# 06-network.sh — when a host firewall (ufw) blocks the Incus bridge, the yard can't
# reach the host's dnsmasq (no DHCP/DNS) and, with Docker on the host setting FORWARD
# policy DROP, its TCP egress is dropped too (ICMP/DNS still pass — misleading). Open it
# narrowly: DHCP (udp/67) + DNS (53) inbound, and route in/out for the bridge. No host
# services are exposed. Root; idempotent. No-op when ufw is inactive.
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

# --- skip if no blocking host firewall (read-only, no sudo) ------------------
# Only ufw is handled: it owns INPUT and its default 'deny incoming' is what blocks
# the bridge. Other setups (no firewall, or Incus-managed nftables) need no host rule.
if ! command -v ufw >/dev/null 2>&1 || ! systemctl is-active --quiet ufw 2>/dev/null; then
  ok "ufw not active — Incus manages the bridge firewall; no host rule needed"
  exit 0
fi

announce "Subyard — open host DHCP/DNS + egress for the yard bridge '$BRIDGE'" \
  "ufw is active: 'deny incoming' blocks the yard from the host's dnsmasq, and the host's" \
  "Docker sets FORWARD policy DROP, which blocks the yard's TCP egress (ICMP/DNS still pass)." \
  "Add interface-scoped ufw rules (no IPs/subnets): inbound on '$BRIDGE' to DHCP (udp/67) + DNS (53)," \
  "and route in/out on '$BRIDGE' so the yard reaches the internet. No host services exposed." \
  "Reversible: 'sudo ufw status numbered' then 'sudo ufw delete' the '$BRIDGE' rules."
proceed_or_die
require_root "adding host ufw rules requires root"

echo "ufw rules for $BRIDGE (idempotent — re-adds print 'Skipping adding existing rule'):"
# Host services: only DHCP + DNS to the host's dnsmasq (narrow; nothing else exposed).
ufw allow in on "$BRIDGE" to any port 67 proto udp
ufw allow in on "$BRIDGE" to any port 53
# Egress: let the yard route out. Host Docker's FORWARD policy DROP otherwise drops the
# yard's new TCP connections (ICMP/DNS still pass, which hides the problem).
ufw route allow in on "$BRIDGE"
ufw route allow out on "$BRIDGE"

echo
ok "Network host-rules done."
cat <<MSG

Verify:
  sudo ufw status | grep $BRIDGE
  incus exec yard --project subyard -- curl -4 -sS --max-time 8 -o /dev/null -w 'egress http=%{http_code}\n' https://deb.debian.org/
MSG
