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
reconcile_registry_validate
[ "$(reconcile_stage_prefix keys)" = stage_keys ] \
  || { printf 'FAIL: yard init has no credential-ledger stage\n' >&2; exit 1; }
declare -f stage_keys_apply | grep -Fq keys_init_store \
  || { printf 'FAIL: yard init does not create the credential ledger\n' >&2; exit 1; }

stage_fixture_check() { [ -f "$TMP/converged" ]; }
stage_fixture_plan() { printf 'fixture convergence\n'; }
stage_fixture_apply() { printf 'applied\n' >> "$TMP/log"; : > "$TMP/converged"; }
stage_fixture_verify() { stage_fixture_check; }
RECONCILE_STAGES=('fixture|stage_fixture')

reconcile_run_stages
reconcile_run_stages
[ "$(wc -l < "$TMP/log")" -eq 1 ] || { printf 'FAIL: converged stage reapplied\n' >&2; exit 1; }

printf 'ok: init stage registry applies once and verifies convergence\n'
