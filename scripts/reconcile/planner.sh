#!/usr/bin/env bash
# planner.sh — ordered plan/apply/verify orchestration over the typed stage registry.
# shellcheck disable=SC2034 # RECONCILE_PENDING is the planner's caller-visible result.

[ -n "${SUBYARD_RECONCILE_PLANNER_SOURCED:-}" ] && return 0
SUBYARD_RECONCILE_PLANNER_SOURCED=1

# shellcheck source=scripts/reconcile/finalize.sh
. "$RECONCILE_DIR/finalize.sh"

reconcile_plan_do() {
  printf '  %s[do]%s   %s\n' "$C_OK" "$C_OFF" "$1"
  RECONCILE_PENDING=1
}
reconcile_plan_skip() { printf '  %s[skip]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }

reconcile_print_plan() {
  local row id _prefix label
  RECONCILE_PENDING=0
  printf '\n%sSubyard init — full bring-up%s\n%sThis run will (finished steps are skipped):%s\n' \
    "$C_HEAD" "$C_OFF" "$C_HEAD" "$C_OFF"
  reconcile_registry_validate
  for row in "${RECONCILE_STAGES[@]}"; do
    IFS='|' read -r id _prefix <<<"$row"
    label="$(reconcile_stage_call "$id" plan)"
    if reconcile_stage_call "$id" check; then
      reconcile_plan_skip "$label"
    else
      reconcile_plan_do "$label"
    fi
  done
  printf '\n'
}

reconcile_run_stages() {
  local row id _prefix label
  reconcile_registry_validate
  for row in "${RECONCILE_STAGES[@]}"; do
    IFS='|' read -r id _prefix <<<"$row"
    if reconcile_stage_call "$id" check; then
      info "→ $id (already converged)"
      continue
    fi
    info "→ $id"
    reconcile_stage_call "$id" apply
    if ! reconcile_stage_call "$id" verify; then
      label="$(reconcile_stage_call "$id" plan)"
      die "init stage '$id' completed but did not converge: $label"
    fi
  done
}

reconcile_run_finalization() {
  local label
  stage_finalize_check && return 0
  label="$(stage_finalize_plan)"
  info "→ finalization"
  stage_finalize_apply
  stage_finalize_verify || die "init finalization completed but did not converge: $label"
}
