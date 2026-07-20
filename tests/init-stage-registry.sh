#!/usr/bin/env bash
# The init plan/executor registry uses the same probe and verifies every applied stage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
mkdir -p "$HOME"

# Sourcing defines the registry and functions but does not run init's main block.
# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"
init_registry_check
keys_stage=-1
for i in "${!INIT_STEP_IDS[@]}"; do
  [ "${INIT_STEP_IDS[$i]}" = keys ] && keys_stage="$i"
done
[ "$keys_stage" -ge 0 ] || { printf 'FAIL: yard init has no credential-ledger stage\n' >&2; exit 1; }
[ "${INIT_STEP_APPLY[$keys_stage]}" = apply_keys ] \
  || { printf 'FAIL: yard init credential-ledger stage uses the wrong reconciler\n' >&2; exit 1; }
declare -f apply_keys | grep -Fq keys_init_store \
  || { printf 'FAIL: yard init does not create the credential ledger\n' >&2; exit 1; }

probe_fixture() { [ -f "$TMP/converged" ]; }
apply_fixture() { printf 'applied\n' >> "$TMP/log"; : > "$TMP/converged"; }
incus_install_or_upgrade() { :; }
INIT_STEP_IDS=(fixture)
INIT_STEP_PROBES=(probe_fixture)
INIT_STEP_APPLY=(apply_fixture)
INIT_STEP_VERIFY=(probe_fixture)
INIT_STEP_LABELS=("fixture convergence")

run_steps
run_steps
[ "$(wc -l < "$TMP/log")" -eq 1 ] || { printf 'FAIL: converged stage reapplied\n' >&2; exit 1; }

printf 'ok: init stage registry applies once and verifies convergence\n'
