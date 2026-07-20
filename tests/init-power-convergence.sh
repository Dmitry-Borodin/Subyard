#!/usr/bin/env bash
# A fresh yard can install the boot reconciler before its desired-power transaction is finalized.
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

[ "${INIT_STEP_PROBES[9]}" = have_power ] \
  || fail "power stage no longer detects unfinished desired-power metadata"
[ "${INIT_STEP_VERIFY[9]}" = have_power_reconciler ] \
  || fail "power stage immediately requires final desired-power metadata"

metadata_ready=0
reconciler_ready=0
apply_count=0
have_power() { [ "$metadata_ready" = 1 ] && have_power_reconciler; }
have_power_reconciler() { [ "$reconciler_ready" = 1 ]; }
apply_power() { apply_count=$((apply_count + 1)); reconciler_ready=1; }
incus_install_or_upgrade() { :; }

INIT_STEP_IDS=(power)
INIT_STEP_PROBES=(have_power)
INIT_STEP_APPLY=(apply_power)
INIT_STEP_VERIFY=(have_power_reconciler)
INIT_STEP_LABELS=("fixture power convergence")

# This is the state from a newly created yard: the reconciler install must verify successfully
# while initialized=false remains pending for the post-profile finalization.
run_steps
[ "$apply_count" -eq 1 ] || fail "fresh power stage was not applied exactly once"
[ "$metadata_ready" -eq 0 ] || fail "power install unexpectedly finalized metadata"

# Once finalization commits initialized=true, a resumed init must skip the stage.
metadata_ready=1
run_steps
[ "$apply_count" -eq 1 ] || fail "finalized power stage was reapplied"

printf 'ok: fresh init defers final power convergence until finalization\n'
