#!/usr/bin/env bash
# Reconcile stage for the opt-in nested VM backend.

[ -n "${SUBYARD_STAGE_TEST_VMS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_TEST_VMS_SOURCED=1

# shellcheck source=scripts/lib/e2e-agent-enrollment.sh
. "$SCRIPT_DIR/lib/e2e-agent-enrollment.sh"

stage_test_vms_revision() {
  sha256sum "$SCRIPT_DIR/e2e-lab/worker.sh" "$SCRIPT_DIR/e2e-lab/status.sh" \
    "$SCRIPT_DIR/e2e-lab/provision.sh" "$SCRIPT_DIR/e2e-lab/reconcile.sh" \
    "$SCRIPT_DIR/lib/e2e-agent-enrollment.sh" \
    | sha256sum | awk '{print $1}'
}

stage_test_vms_worker_hash() { sha256sum "$SCRIPT_DIR/e2e-lab/worker.sh" | awk '{print $1}'; }
stage_test_vms_status_hash() { sha256sum "$SCRIPT_DIR/e2e-lab/status.sh" | awk '{print $1}'; }

stage_test_vms_check_fail() {
  [ "${SUBYARD_TEST_VMS_CHECK_VERBOSE:-0}" = 1 ] \
    && printf '  [fail] test-vms convergence: %s\n' "$*" >&2
  return 1
}

stage_test_vms_check() {
  reconcile_incus_reachable \
    || { stage_test_vms_check_fail "outer Incus is not reachable"; return 1; }
  local desired revision worker_hash status_hash marker agent_key_hash agent_configured=0 client_dir
  local agent_public_key='' enrollment_rc inner_output
  desired="${NESTED_E2E_VMS:-0}"
  revision="$(stage_test_vms_revision)"
  worker_hash="$(stage_test_vms_worker_hash)"
  status_hash="$(stage_test_vms_status_hash)"
  client_dir="${SUBYARD_E2E_CLIENT_EXPORT_DIR:-$SCRIPT_DIR/../temp/agent-e2e/${YARD_NAME:-default}}"
  if e2e_agent_enrollment_read "$client_dir"; then
    agent_public_key="$E2E_AGENT_PUBLIC_KEY"
    agent_configured=1
  else
    enrollment_rc=$?
    [ "$enrollment_rc" -eq 1 ] \
      || { stage_test_vms_check_fail "agent-access.pub is not one regular Ed25519 public-key line"; return 1; }
  fi
  agent_key_hash="$(printf '%s' "$agent_public_key" | sha256sum | awk '{print $1}')"
  marker="$(incus config get "$INSTANCE_NAME" user.subyard.test_vms_revision "${PROJ[@]}" 2>/dev/null || true)"
  [ "$marker" = "$desired:$revision:$agent_key_hash" ] \
    || { stage_test_vms_check_fail "outer instance revision marker differs from the requested backend/key"; return 1; }
  if [ "$desired" = 1 ] && [ "$agent_configured" = 1 ]; then
    [ -r "$client_dir/route.tsv" ] && [ -r "$client_dir/known_hosts" ] \
      || { stage_test_vms_check_fail "published agent route or bastion host-key pin is missing"; return 1; }
    [ "$(sed -n '1p' "$client_dir/route.tsv")" = subyard-e2e-route-v1 ] \
      || { stage_test_vms_check_fail "published agent route has an unknown format"; return 1; }
    ssh-keygen -F subyard-e2e-bastion -f "$client_dir/known_hosts" >/dev/null \
      || { stage_test_vms_check_fail "published bastion host-key pin is invalid"; return 1; }
  else
    [ ! -e "$client_dir/route.tsv" ] && [ ! -e "$client_dir/known_hosts" ] \
      || { stage_test_vms_check_fail "agent route remains published while enrollment is disabled"; return 1; }
  fi
  if ! reconcile_instance_running; then
    reconcile_power_stopped \
      || { stage_test_vms_check_fail "yard instance is neither running nor converged as stopped"; return 1; }
    return
  fi
  if ! inner_output="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env WANT_ENABLED="$desired" --env WANT_WORKER_HASH="$worker_hash" \
    --env WANT_STATUS_HASH="$status_hash" --env WANT_AGENT_CONFIGURED="$agent_configured" \
    --env WANT_AGENT_KEY_HASH="$agent_key_hash" \
    -- sh -eu -s 2>&1 <<'CHECK'
check_fail() { printf 'inner yard: %s\n' "$*" >&2; exit 1; }
worker=/usr/local/libexec/subyard/test-vms-inner
status=/usr/local/libexec/subyard/test-vms-status
config=/etc/subyard/test-vms.env
[ -x "$worker" ] || check_fail "lifecycle worker is missing or not executable"
[ -x "$status" ] || check_fail "forced-status worker is missing or not executable"
[ -r "$config" ] || check_fail "root-owned backend config is missing or unreadable"
actual="$(sha256sum "$worker" | awk '{print $1}')" \
  || check_fail "could not hash the installed lifecycle worker"
[ "$actual" = "$WANT_WORKER_HASH" ] || check_fail "installed lifecycle worker hash differs"
actual="$(sha256sum "$status" | awk '{print $1}')" \
  || check_fail "could not hash the installed forced-status worker"
[ "$actual" = "$WANT_STATUS_HASH" ] || check_fail "installed forced-status worker hash differs"
. "$config" || check_fail "could not load the backend config"
[ "${NESTED_E2E_VMS:-0}" = "$WANT_ENABLED" ] \
  || check_fail "backend enabled state differs"
[ "$(printf '%s' "${E2E_AGENT_PUBLIC_KEY:-}" | sha256sum | awk '{print $1}')" = "$WANT_AGENT_KEY_HASH" ] \
  || check_fail "installed agent public key differs from the enrollment request"
if [ "$WANT_ENABLED" = 1 ]; then
  for command_name in incus qemu-system-x86_64 nft; do
    command -v "$command_name" >/dev/null \
      || check_fail "required command is missing: $command_name"
  done
  dpkg --compare-versions "$(incus --version)" ge 6.0.6 \
    || check_fail "inner Incus is older than 6.0.6"
  systemctl is-active --quiet incus.service \
    || check_fail "inner Incus service is not active"
  grep -Fxq 'Environment=INCUS_SECURITY_APPARMOR=false' \
    /etc/systemd/system/incus.service.d/subyard-nested-e2e.conf \
    || check_fail "inner Incus AppArmor compatibility drop-in differs"
  systemctl is-enabled --quiet subyard-test-vms-gc.timer \
    || check_fail "nested VM TTL cleanup timer is not enabled"
  systemctl is-active --quiet subyard-test-vms-firewall.service \
    || check_fail "nested VM firewall service is not active"
  nft list table inet subyard_e2e >/dev/null \
    || check_fail "nested VM firewall table is missing"
  sshd_config="$(sshd -T)" || check_fail "could not render effective sshd configuration"
  printf '%s\n' "$sshd_config" | grep -Fx 'passwordauthentication no' >/dev/null \
    || check_fail "SSH password authentication is not disabled"
  printf '%s\n' "$sshd_config" | grep -Fx 'kbdinteractiveauthentication no' >/dev/null \
    || check_fail "SSH keyboard-interactive authentication is not disabled"
  for node in /dev/kvm /dev/vsock /dev/vhost-vsock /dev/net/tun; do
    [ -c "$node" ] || check_fail "required nested-VM device is missing: $node"
  done
  actual="$(stat -c '%U:%G:%a' /var/lib/subyard/test-vms)" \
    || check_fail "could not inspect lifecycle state directory"
  [ "$actual" = root:root:700 ] \
    || check_fail "lifecycle state directory ownership/mode is $actual; expected root:root:700"
  dev_groups="$(id -nG "$DEV_USER")" || check_fail "yard developer account is missing"
  case " $dev_groups " in
    *' incus-admin '* | *' yard '*) check_fail "yard developer still belongs to a privileged inner group" ;;
  esac
  if [ "$WANT_AGENT_CONFIGURED" = 1 ]; then
    id -u subyard-e2e-agent >/dev/null \
      || check_fail "restricted agent account is missing"
    account_status="$(passwd --status subyard-e2e-agent)" \
      || check_fail "could not inspect restricted agent account status"
    case "$account_status" in 'subyard-e2e-agent P '*) ;; *) check_fail "restricted agent account is not key-login capable" ;; esac
    agent_groups="$(id -nG subyard-e2e-agent)" \
      || check_fail "could not inspect restricted agent groups"
    [ "$(printf '%s\n' "$agent_groups" | wc -w)" -eq 1 ] \
      || check_fail "restricted agent has supplementary groups"
    agent_group="$(id -gn subyard-e2e-agent)" \
      || check_fail "could not inspect restricted agent primary group"
    actual="$(stat -c '%U:%G:%a' /var/lib/subyard/e2e-agent/.ssh)" \
      || check_fail "could not inspect restricted agent SSH directory"
    [ "$actual" = "root:$agent_group:750" ] \
      || check_fail "restricted agent SSH directory ownership/mode is $actual; expected root:$agent_group:750"
    actual="$(stat -c '%U:%G:%a' /var/lib/subyard/e2e-agent/.ssh/authorized_keys)" \
      || check_fail "could not inspect restricted agent authorized_keys"
    [ "$actual" = "root:$agent_group:640" ] \
      || check_fail "restricted agent authorized_keys ownership/mode is $actual; expected root:$agent_group:640"
    grep -q '^restrict,' /var/lib/subyard/e2e-agent/.ssh/authorized_keys \
      || check_fail "restricted agent key has no fail-closed SSH restrictions"
    grep -Fq 'command="/usr/local/libexec/subyard/test-vms-status"' \
      /var/lib/subyard/e2e-agent/.ssh/authorized_keys \
      || check_fail "restricted agent key has no forced status command"
  else
    ! id -u subyard-e2e-agent >/dev/null 2>&1 \
      || check_fail "restricted agent account remains while enrollment is disabled"
  fi
else
  ! systemctl is-active --quiet subyard-test-vms-gc.timer \
    || check_fail "nested VM TTL cleanup timer remains active while disabled"
  ! systemctl is-active --quiet subyard-test-vms-firewall.service \
    || check_fail "nested VM firewall remains active while disabled"
  [ ! -e /etc/systemd/system/incus.service.d/subyard-nested-e2e.conf ] \
    || check_fail "inner Incus compatibility drop-in remains while disabled"
  [ ! -e /etc/ssh/sshd_config.d/90-subyard-e2e-agent.conf ] \
    || check_fail "restricted SSH policy remains while disabled"
  ! id -u subyard-e2e-agent >/dev/null 2>&1 \
    || check_fail "restricted agent account remains while disabled"
fi
CHECK
  )"; then
    stage_test_vms_check_fail "${inner_output:-inner-yard validation failed without details}"
    return 1
  fi
}

stage_test_vms_plan() {
  if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
    printf 'Install/reconcile the trusted two-VM test backend inside the yard\n'
  else
    printf 'Keep the nested VM test backend disabled\n'
  fi
}
stage_test_vms_apply() { "$SCRIPT_DIR/e2e-lab/reconcile.sh" --yes; }
stage_test_vms_verify() { SUBYARD_TEST_VMS_CHECK_VERBOSE=1 stage_test_vms_check; }
