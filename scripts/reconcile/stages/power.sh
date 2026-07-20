#!/usr/bin/env bash
# power.sh — desired-power metadata and guarded host boot reconciler stage.

[ -n "${SUBYARD_STAGE_POWER_SOURCED:-}" ] && return 0
SUBYARD_STAGE_POWER_SOURCED=1

stage_power_reconciler_check() {
  local unit="${SUBYARD_POWER_UNIT_PATH:-/etc/systemd/system/subyard-power-reconcile.service}"
  local reconciler="${SUBYARD_POWER_RECONCILER_PATH:-/usr/local/libexec/subyard/yard-boot-reconcile}"
  local power_lib="${SUBYARD_POWER_LIB_PATH:-/usr/local/libexec/subyard/lib-power.sh}"
  [ -x "$reconciler" ] && [ -r "$power_lib" ] && [ -r "$unit" ] \
    && cmp -s "$SCRIPT_DIR/yard-boot-reconcile.sh" "$reconciler" \
    && cmp -s "$SCRIPT_DIR/lib-power.sh" "$power_lib" \
    && grep -qF "ExecStart=$reconciler" "$unit" \
    && systemctl is-enabled --quiet "$(basename "$unit")" 2>/dev/null
}

stage_power_check() {
  stage_instance_check \
    && power_metadata_ready "$INCUS_PROJECT" "$INSTANCE_NAME" "$INCUS_BRIDGE" \
    && stage_power_import_check \
    && stage_power_reconciler_check
}
stage_power_plan() {
  printf 'Persist desired yard power + install guarded host boot reconciliation (needs root)\n'
}
stage_power_apply() { "$SCRIPT_DIR/install-power-reconciler.sh" --yes; }
# Final desired-power metadata is committed only after the optional provisioning offer.
stage_power_verify() { stage_power_reconciler_check; }
