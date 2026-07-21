#!/usr/bin/env bash
# test-vms.sh — opt-in nested VM backend stage.

[ -n "${SUBYARD_STAGE_TEST_VMS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_TEST_VMS_SOURCED=1

stage_test_vms_revision() {
  sha256sum "$SCRIPT_DIR/test-vms-inner.sh" "$SCRIPT_DIR/provision-test-vms-inner.sh" \
    | sha256sum | awk '{print $1}'
}

stage_test_vms_worker_hash() { sha256sum "$SCRIPT_DIR/test-vms-inner.sh" | awk '{print $1}'; }

stage_test_vms_check() {
  reconcile_incus_reachable || return 1
  local desired revision worker_hash marker
  desired="${NESTED_E2E_VMS:-0}"
  revision="$(stage_test_vms_revision)"
  worker_hash="$(stage_test_vms_worker_hash)"
  marker="$(incus config get "$INSTANCE_NAME" user.subyard.test_vms_revision "${PROJ[@]}" 2>/dev/null || true)"
  [ "$marker" = "$desired:$revision" ] || return 1
  if ! reconcile_instance_running; then
    reconcile_power_stopped
    return
  fi
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env WANT_ENABLED="$desired" --env WANT_WORKER_HASH="$worker_hash" -- sh -eu -s >/dev/null 2>&1 <<'CHECK' || return 1
worker=/usr/local/libexec/subyard/test-vms-inner
config=/etc/subyard/test-vms.env
[ -x "$worker" ] && [ -r "$config" ]
actual="$(sha256sum "$worker" | awk '{print $1}')"
[ "$actual" = "$WANT_WORKER_HASH" ]
. "$config"
[ "${NESTED_E2E_VMS:-0}" = "$WANT_ENABLED" ]
if [ "$WANT_ENABLED" = 1 ]; then
  command -v incus >/dev/null
  command -v qemu-system-x86_64 >/dev/null
  dpkg --compare-versions "$(incus --version)" ge 6.0.6
  systemctl is-active --quiet incus.service
  systemctl is-enabled --quiet subyard-test-vms-gc.timer
  for node in /dev/kvm /dev/vsock /dev/vhost-vsock /dev/net/tun; do [ -c "$node" ]; done
else
  ! systemctl is-active --quiet subyard-test-vms-gc.timer
fi
CHECK
}

stage_test_vms_plan() {
  if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
    printf 'Install/reconcile the trusted two-VM test backend inside the yard\n'
  else
    printf 'Keep the nested VM test backend disabled\n'
  fi
}
stage_test_vms_apply() { "$SCRIPT_DIR/reconcile-test-vms.sh" --yes; }
stage_test_vms_verify() { stage_test_vms_check; }
