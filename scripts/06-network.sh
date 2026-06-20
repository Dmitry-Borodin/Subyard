#!/usr/bin/env bash
# 06-network.sh — when a host firewall (ufw) blocks the Incus bridge, the yard can't
# reach the host's dnsmasq and gets no DHCP/DNS. Open it narrowly: only DHCP (udp/67)
# and DNS (53) inbound on the bridge — nothing else of the host is exposed to the yard.
# Root; idempotent. No-op when ufw is inactive (Incus then manages the bridge firewall).
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

announce "Subyard — open host DHCP/DNS for the yard bridge '$BRIDGE'" \
  "ufw is active and its 'deny incoming' blocks the yard from the host's dnsmasq." \
  "Add narrow ufw rules: allow inbound on '$BRIDGE' to DHCP (udp/67) and DNS (53) only." \
  "Nothing else of the host is exposed; interface-scoped, no IPs hardcoded." \
  "Reversible: 'sudo ufw delete' the two rules ('sudo ufw status numbered' to find them)."
proceed_or_die
require_root "adding host ufw rules requires root"

echo "ufw rules ($BRIDGE → host, DHCP+DNS only):"
# ufw is idempotent: re-adding prints "Skipping adding existing rule".
ufw allow in on "$BRIDGE" to any port 67 proto udp
ufw allow in on "$BRIDGE" to any port 53

echo
ok "Network host-rules done."
cat <<MSG

Verify:
  sudo ufw status | grep $BRIDGE
  incus exec yard --project subyard -- getent hosts deb.debian.org   # resolves
MSG
