#!/usr/bin/env bash
# Reconcile the opt-in nested VM lab inside L1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
. "$ROOT/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$ROOT/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$ROOT/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=scripts/lib/e2e-agent-enrollment.sh
. "$ROOT/lib/e2e-agent-enrollment.sh"
subyard_context_load
# shellcheck source=scripts/lib-power.sh
. "$ROOT/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$ROOT/lib/host.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
WORKER_SRC="$SCRIPT_DIR/worker.sh"
STATUS_SRC="$SCRIPT_DIR/status.sh"
PROVISION_SRC="$SCRIPT_DIR/provision.sh"
RECONCILE_SRC="$SCRIPT_DIR/reconcile.sh"
WORKER_DST=/usr/local/libexec/subyard/test-vms-inner
STATUS_DST=/usr/local/libexec/subyard/test-vms-status
CLIENT_EXPORT_DIR="${SUBYARD_E2E_CLIENT_EXPORT_DIR:-$ROOT/../temp/agent-e2e/${YARD_NAME:-default}}"
desired="${NESTED_E2E_VMS:-0}"
agent_public_key=''
agent_fingerprint=''
if e2e_agent_enrollment_read "$CLIENT_EXPORT_DIR"; then
  agent_public_key="$E2E_AGENT_PUBLIC_KEY"
  agent_fingerprint="$E2E_AGENT_PUBLIC_KEY_FINGERPRINT"
else
  enrollment_rc=$?
  [ "$enrollment_rc" -eq 1 ] \
    || die "agent enrollment request must be one regular Ed25519 public-key line: $CLIENT_EXPORT_DIR/agent-access.pub"
fi
agent_key_hash="$(printf '%s' "$agent_public_key" | sha256sum | awk '{print $1}')"
revision="$(sha256sum "$WORKER_SRC" "$STATUS_SRC" "$PROVISION_SRC" "$RECONCILE_SRC" \
  "$ROOT/lib/e2e-agent-enrollment.sh" \
  | sha256sum | awk '{print $1}')"
marker="$desired:$revision:$agent_key_hash"
agent_summary="Keep agent SSH ingress disabled (no machine-scoped public key is enrolled)."
if [ -n "$agent_public_key" ]; then
  agent_summary="Enroll the requested agent/controller key ($agent_fingerprint) without copying its private half."
fi

publish_agent_client_route() {
  local route_tmp known_tmp outer_ip host_key alias=subyard-e2e-bastion
  install -d -m 0755 "$CLIENT_EXPORT_DIR"
  route_tmp="$(mktemp "$CLIENT_EXPORT_DIR/.route.XXXXXX")"
  known_tmp="$(mktemp "$CLIENT_EXPORT_DIR/.known-hosts.XXXXXX")"
  outer_ip="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -eu -c '
    interface="$(ip -4 -o route show default | awk '\''NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'\'')"
    [ -n "$interface" ]
    ip -4 -o address show dev "$interface" scope global \
      | awk '\''NR == 1 { split($4, address, "/"); print address[1]; found = 1 } END { exit !found }'\''
  ')" || { rm -f "$route_tmp" "$known_tmp"; die "could not resolve the agent route to $INSTANCE_NAME"; }
  host_key="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- \
    awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' \
      /etc/ssh/ssh_host_ed25519_key.pub)" \
    || { rm -f "$route_tmp" "$known_tmp"; die "could not read $INSTANCE_NAME SSH host key"; }
  [[ "$outer_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] \
    || { rm -f "$route_tmp" "$known_tmp"; die "unsafe outer-yard IPv4 address"; }
  [[ "$host_key" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]] \
    || { rm -f "$route_tmp" "$known_tmp"; die "invalid outer-yard SSH host key"; }
  {
    printf 'subyard-e2e-route-v1\n'
    printf 'hostname\t%s\n' "$outer_ip"
    printf 'port\t22\n'
    printf 'host_key_alias\t%s\n' "$alias"
  } > "$route_tmp"
  printf '%s %s\n' "$alias" "$host_key" > "$known_tmp"
  chmod 0644 "$route_tmp" "$known_tmp"
  mv -f "$route_tmp" "$CLIENT_EXPORT_DIR/route.tsv"
  mv -f "$known_tmp" "$CLIENT_EXPORT_DIR/known_hosts"
}

remove_agent_client_route() {
  rm -f "$CLIENT_EXPORT_DIR/route.tsv" "$CLIENT_EXPORT_DIR/known_hosts"
}

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "yard instance '$INSTANCE_NAME' is missing"

if [ "$desired" = 1 ]; then
  summary=(
    "Inside the yard: install Incus >= 6.0.6, QEMU and an isolated dir pool/bridge."
    "Install a fixed two-VM lifecycle worker and a ten-minute TTL cleanup timer."
    "Keep '$DEV_USER' out of inner Incus and install a no-shell SSH bastion for the enrolled agent key."
    "$agent_summary"
    "Permit agent forwarding only to SSH on the two ready managed VMs; publish read-only allocation status."
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
incus file push "$STATUS_SRC" "$INSTANCE_NAME$STATUS_DST" "${PROJ[@]}" \
  --create-dirs --uid 0 --gid 0 --mode 0755
incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
  --env NESTED_E2E_VMS="$desired" \
  --env DEV_USER="${DEV_USER:-dev}" \
  --env E2E_VM_IMAGE="${E2E_VM_IMAGE:-images:debian/13/cloud}" \
  --env E2E_VM_CPU="${E2E_VM_CPU:-2}" \
  --env E2E_VM_MEMORY="${E2E_VM_MEMORY:-4GiB}" \
  --env E2E_VM_DISK="${E2E_VM_DISK:-10GiB}" \
  --env E2E_VM_TTL_MINUTES="${E2E_VM_TTL_MINUTES:-240}" \
  --env E2E_VM_BOOT_TIMEOUT="${E2E_VM_BOOT_TIMEOUT:-300}" \
  --env E2E_AGENT_PUBLIC_KEY="$agent_public_key" \
  -- bash -euo pipefail -s < "$PROVISION_SRC"

if [ "$desired" = 1 ] && [ -n "$agent_public_key" ]; then
  publish_agent_client_route
else
  remove_agent_client_route
fi

incus config set "$INSTANCE_NAME" user.subyard.test_vms_revision "$marker" "${PROJ[@]}"

if [ "$temporary_start" = 1 ]; then
  info "restoring $INSTANCE_NAME to desired=stopped"
  power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME" || die "$POWER_ERROR"
  temporary_start=0
fi
trap - EXIT
ok "nested E2E VM backend reconciled (enabled=$desired)"
