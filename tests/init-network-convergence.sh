#!/usr/bin/env bash
# Active UFW converges only when its persisted bridge rules and the NetworkManager guard match.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
export SUBYARD_UFW_RULES_FILE="$TMP/user.rules"
mkdir -p "$HOME"
cat > "$SUBYARD_UFW_RULES_FILE" <<'RULES'
### tuple ### allow udp 67 0.0.0.0/0 any 0.0.0.0/0 in_incusbr0
### tuple ### allow any 53 0.0.0.0/0 any 0.0.0.0/0 in_incusbr0
### tuple ### route:allow any any 0.0.0.0/0 any 0.0.0.0/0 in_incusbr0
### tuple ### route:allow any any 0.0.0.0/0 any 0.0.0.0/0 out_incusbr0
RULES

# shellcheck source=scripts/lib/host.sh
. "$ROOT/scripts/lib/host.sh"

ufw_yard_rules_present incusbr0 || fail "matching active-UFW rules were not converged"
sed -i '/out_incusbr0/d' "$SUBYARD_UFW_RULES_FILE"
! ufw_yard_rules_present incusbr0 || fail "missing UFW route-out rule was accepted"
printf '%s\n' '### tuple ### route:allow any any 0.0.0.0/0 any 0.0.0.0/0 out_incusbr0' \
  >> "$SUBYARD_UFW_RULES_FILE"

access_log="$TMP/access.log"
getent() { [ "${1:-}" = group ] && [ "${2:-}" = incus-admin ]; }
chgrp() { printf 'chgrp %s %s\n' "$1" "$2" >>"$access_log"; }
chmod() { printf 'chmod %s %s\n' "$1" "$2" >>"$access_log"; }
ufw_rules_set_probe_access enable || fail "could not enable UFW probe access"
ufw_rules_set_probe_access disable || fail "could not restore root-only UFW access"
grep -Fqx "chgrp incus-admin $SUBYARD_UFW_RULES_FILE" "$access_log" \
  || fail "UFW probe access did not use incus-admin"
grep -Fqx "chgrp root $SUBYARD_UFW_RULES_FILE" "$access_log" \
  || fail "UFW teardown access did not restore root ownership"

printf 'ok: network leaf parses persisted active-UFW policy\n'
