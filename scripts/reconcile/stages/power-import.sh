#!/usr/bin/env bash
# power-import.sh — import desired-power metadata for every registered local yard.

[ -n "${SUBYARD_STAGE_POWER_IMPORT_SOURCED:-}" ] && return 0
SUBYARD_STAGE_POWER_IMPORT_SOURCED=1

stage_power_import_check() {
  reconcile_incus_reachable || return 1
  ! "$SCRIPT_DIR/power-state.sh" needs-import-any >/dev/null 2>&1
}
stage_power_import_plan() { printf 'Import desired-power state for registered local yards\n'; }
stage_power_import_apply() { "$SCRIPT_DIR/power-state.sh" import-all; }
stage_power_import_verify() { stage_power_import_check; }
