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

# The native engine exports the selected yard as INCUS_PROJECT, which is also interpreted by the
# Incus CLI. Before a named project's creation, host pool/network probes must remain in `default`.
INCUS_PROJECT=subyard-e2e-yard
PROJ=(--project "$INCUS_PROJECT")
STORAGE_POOL=default
INCUS_BRIDGE=incusbr0
reconcile_incus_reachable() { return 0; }
incus() {
  case "$*" in
    'storage show default --project default' | 'network show incusbr0 --project default') return 0 ;;
    *) return 1 ;;
  esac
}
stage_incus_initialized \
  || { printf 'FAIL: named yard redirected host bootstrap probes away from default project\n' >&2; exit 1; }

incus() {
  [ "$*" = "info yard --project $INCUS_PROJECT" ]
}
stage_instance_exists \
  || { printf 'FAIL: existing base-yard detection did not use the selected Incus project\n' >&2; exit 1; }

printf 'ok: init stage registry applies once and verifies convergence\n'
