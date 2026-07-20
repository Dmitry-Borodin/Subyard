#!/usr/bin/env bash
# finalize.sh — separate desired-power transaction committed after optional profile provisioning.

[ -n "${SUBYARD_RECONCILE_FINALIZE_SOURCED:-}" ] && return 0
SUBYARD_RECONCILE_FINALIZE_SOURCED=1

stage_finalize_check() { stage_power_check; }
stage_finalize_plan() { printf 'Restore and commit the configured desired yard power state\n'; }
stage_finalize_apply() { "$SCRIPT_DIR/power-state.sh" finalize; }
stage_finalize_verify() { stage_finalize_check; }
