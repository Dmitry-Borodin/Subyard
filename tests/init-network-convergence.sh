#!/usr/bin/env bash
# Active ufw keeps the conservative network probe pending but must not fail post-apply verification.
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
mkdir -p "$HOME"

# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"
reachable() { return 0; }
power_host_safe() { return 0; }
have_instance() { return 1; }
power_stopped() { return 0; }
ufw() { :; }
systemctl() { return 0; }

! have_network || fail "active ufw should keep the conservative probe pending"
verify_network || fail "active ufw rejected a converged post-apply state"
[ "${INIT_STEP_VERIFY[1]}" = verify_network ] || fail "network registry uses the conservative probe as verify"

# The guard is applied before a fresh yard instance exists, so post-apply verification must not
# require a guest lease that the instance stage has not created yet.
power_stopped() { return 1; }
verify_network || fail "fresh-host network verify required a not-yet-created instance"

printf 'ok: network apply verification is independent of the active-ufw probe\n'
