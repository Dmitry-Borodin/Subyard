#!/usr/bin/env bash
# facts.sh — shared read-only runtime facts used by reconciliation stages.

[ -n "${SUBYARD_RECONCILE_FACTS_SOURCED:-}" ] && return 0
SUBYARD_RECONCILE_FACTS_SOURCED=1

reconcile_incus_reachable() { command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; }

reconcile_host_has_kvm() { [ -e /dev/kvm ]; }

reconcile_instance_running() {
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]
}

reconcile_power_stopped() {
  stage_instance_check && power_intentionally_stopped "$INCUS_PROJECT" "$INSTANCE_NAME"
}
