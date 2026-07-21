#!/usr/bin/env bash
# reconcile-test-vms.sh — install/reconcile the opt-in nested VM lab inside L1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
WORKER_SRC="$SCRIPT_DIR/test-vms-inner.sh"
PROVISION_SRC="$SCRIPT_DIR/provision-test-vms-inner.sh"
WORKER_DST=/usr/local/libexec/subyard/test-vms-inner
desired="${NESTED_E2E_VMS:-0}"
revision="$(sha256sum "$WORKER_SRC" "$PROVISION_SRC" | sha256sum | awk '{print $1}')"
marker="$desired:$revision"

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "yard instance '$INSTANCE_NAME' is missing"

if [ "$desired" = 1 ]; then
  summary=(
    "Inside the yard: install Incus >= 6.0.6, QEMU and an isolated dir pool/bridge."
    "Install the Go/ShellCheck developer toolchain used to build and validate the candidate in L1."
    "Install a fixed two-VM lifecycle worker and a ten-minute TTL cleanup timer."
    "Add '$DEV_USER' to the INNER incus-admin group; this grants root-equivalent access inside the yard only."
    "No L0 socket, host path or real credential is exposed."
  )
else
  summary=("Disable the nested VM TTL timer; leave already-installed packages inert.")
fi
announce "Subyard — reconcile nested E2E VM backend ($INSTANCE_NAME)" "${summary[@]}"
proceed_or_die

# `yard init` owns reconciliation, not the yard's long-term power intent. A named yard normally
# starts as desired=stopped, so bring it up just for this stage and restore that state even if the
# streamed inner provisioner fails.
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
YARD_LABEL="${YARD_NAME:-default}"
power_import_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
  || die "$POWER_ERROR"
desired_power="$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
temporary_start=0
current_power="$(power_state "$INCUS_PROJECT" "$INSTANCE_NAME")"
if [ "$current_power" != RUNNING ]; then
  [ "$current_power" = STOPPED ] \
    || die "cannot reconcile the nested VM backend while yard state is '${current_power:-unknown}'"
  power_nm_prepare_reader || die "$POWER_ERROR"
  info "temporarily starting $INSTANCE_NAME for nested VM backend reconciliation (desired=$desired_power)"
  power_start_guarded "$INCUS_PROJECT" "$INSTANCE_NAME" "$BRIDGE" || die "$POWER_ERROR"
  [ "$desired_power" != stopped ] || temporary_start=1
fi

restore_temporary_power() {
  local rc=$?
  trap - EXIT
  if [ "$temporary_start" = 1 ]; then
    info "restoring $INSTANCE_NAME to desired=stopped"
    power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME" \
      || { warn "$POWER_ERROR"; rc=1; }
  fi
  exit "$rc"
}
trap restore_temporary_power EXIT

incus file push "$WORKER_SRC" "$INSTANCE_NAME$WORKER_DST" "${PROJ[@]}" \
  --create-dirs --uid 0 --gid 0 --mode 0755
incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
  --env NESTED_E2E_VMS="$desired" \
  --env DEV_USER="${DEV_USER:-dev}" \
  --env E2E_VM_IMAGE="${E2E_VM_IMAGE:-images:debian/13/cloud}" \
  --env E2E_VM_CPU="${E2E_VM_CPU:-2}" \
  --env E2E_VM_MEMORY="${E2E_VM_MEMORY:-4GiB}" \
  --env E2E_VM_DISK="${E2E_VM_DISK:-30GiB}" \
  --env E2E_VM_TTL_MINUTES="${E2E_VM_TTL_MINUTES:-240}" \
  --env E2E_VM_BOOT_TIMEOUT="${E2E_VM_BOOT_TIMEOUT:-300}" \
  -- bash -euo pipefail -s < "$PROVISION_SRC"

incus config set "$INSTANCE_NAME" user.subyard.test_vms_revision "$marker" "${PROJ[@]}"

if [ "$temporary_start" = 1 ]; then
  info "restoring $INSTANCE_NAME to desired=stopped"
  power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME" || die "$POWER_ERROR"
  temporary_start=0
fi
trap - EXIT
ok "nested E2E VM backend reconciled (enabled=$desired)"
