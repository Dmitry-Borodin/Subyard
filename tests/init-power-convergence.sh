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

[ "$(reconcile_stage_prefix power)" = stage_power ] \
  || fail "power stage is missing from the typed registry"
declare -f stage_power_check | grep -Fq power_metadata_ready \
  || fail "power stage no longer detects unfinished desired-power metadata"
declare -f stage_power_verify | grep -Fq stage_power_reconciler_check \
  || fail "power stage immediately requires final desired-power metadata"

metadata_ready=0
reconciler_ready=0
apply_count=0
stage_power_check() { [ "$metadata_ready" = 1 ] && stage_power_reconciler_check; }
stage_power_reconciler_check() { [ "$reconciler_ready" = 1 ]; }
stage_power_apply() { apply_count=$((apply_count + 1)); reconciler_ready=1; }
RECONCILE_STAGES=('power|stage_power')

# This is the state from a newly created yard: the reconciler install must verify successfully
# while initialized=false remains pending for the post-profile finalization.
reconcile_run_stages
[ "$apply_count" -eq 1 ] || fail "fresh power stage was not applied exactly once"
[ "$metadata_ready" -eq 0 ] || fail "power install unexpectedly finalized metadata"

# Once finalization commits initialized=true, a resumed init must skip the stage.
metadata_ready=1
reconcile_run_stages
[ "$apply_count" -eq 1 ] || fail "finalized power stage was reapplied"

printf 'ok: fresh init defers final power convergence until finalization\n'
