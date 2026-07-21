#!/usr/bin/env bash
# Project and instance probes cover the state their stages can reconcile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
mkdir -p "$HOME"

# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"
reconcile_incus_reachable() { return 0; }
MOCK_RESTRICTED=true
MOCK_PROJECT_DEVICES='root eth0'
MOCK_INSTANCE_DEVICES='srv'
MOCK_SRV_SOURCE="$SRV_VOLUME"
MOCK_NESTING=true
MOCK_INTERCEPTION=block
MOCK_BPF=''
MOCK_SSH_LISTEN="tcp:127.0.0.1:$SSH_PORT"
MOCK_HOST_HAS_KVM=false
incus() {
  case "${1:-} ${2:-} ${3:-}" in
    'project show '* | 'info yard '*) return 0 ;;
    'project get subyard')
      case "${4:-}" in
        restricted) printf '%s\n' "$MOCK_RESTRICTED" ;;
        restricted.containers.nesting) printf 'allow\n' ;;
        restricted.containers.privilege) printf 'unprivileged\n' ;;
        restricted.containers.interception) printf '%s\n' "${MOCK_INTERCEPTION:-block}" ;;
        restricted.devices.disk | restricted.devices.unix-char | restricted.devices.proxy) printf 'allow\n' ;;
        restricted.devices.disk.paths) ;;
      esac ;;
    'profile device list') printf '%s\n' $MOCK_PROJECT_DEVICES ;;
    'storage volume show') return 0 ;;
    'config device list') printf '%s\n' $MOCK_INSTANCE_DEVICES ;;
    'config device get')
      if [ "${5:-}" = ssh ]; then
        case "${6:-}" in
          type) printf 'proxy\n' ;;
          listen) printf '%s\n' "$MOCK_SSH_LISTEN" ;;
          connect) printf 'tcp:127.0.0.1:22\n' ;;
        esac
      elif [ "${5:-}" = kvm ] || [ "${5:-}" = e2e-vsock ] \
        || [ "${5:-}" = e2e-vhost-vsock ] || [ "${5:-}" = e2e-tun ]; then
        case "${5:-}" in
          kvm) MOCK_CHAR_SOURCE=/dev/kvm ;;
          e2e-vsock) MOCK_CHAR_SOURCE=/dev/vsock ;;
          e2e-vhost-vsock) MOCK_CHAR_SOURCE=/dev/vhost-vsock ;;
          e2e-tun) MOCK_CHAR_SOURCE=/dev/net/tun ;;
        esac
        case "${6:-}" in
          type) printf 'unix-char\n' ;;
          source | path) printf '%s\n' "$MOCK_CHAR_SOURCE" ;;
        esac
      else
        case "${6:-}" in
          source) printf '%s\n' "$MOCK_SRV_SOURCE" ;;
          path) printf '/srv\n' ;;
          pool) printf '%s\n' "$SRV_POOL" ;;
        esac
      fi ;;
    'config get yard')
      case "${4:-}" in
        security.nesting) printf '%s\n' "$MOCK_NESTING" ;;
        security.syscalls.intercept.bpf | security.syscalls.intercept.bpf.devices)
          printf '%s\n' "${MOCK_BPF:-}" ;;
      esac ;;
  esac
}
reconcile_host_has_kvm() { "$MOCK_HOST_HAS_KVM"; }

stage_project_check || fail "matching project policy rejected"
MOCK_RESTRICTED=false
! stage_project_check || fail "project policy drift accepted"
MOCK_RESTRICTED=true
MOCK_PROJECT_DEVICES=root
! stage_project_check || fail "missing project NIC accepted"
MOCK_PROJECT_DEVICES='root eth0'

stage_instance_check || fail "matching instance state rejected"
MOCK_HOST_HAS_KVM=true
! stage_instance_check || fail "missing KVM device accepted on a KVM host"
MOCK_INSTANCE_DEVICES='srv kvm'
stage_instance_check || fail "matching KVM instance state rejected"
MOCK_HOST_HAS_KVM=false
MOCK_INSTANCE_DEVICES=''
! stage_instance_check || fail "missing srv device accepted"
MOCK_INSTANCE_DEVICES=srv
MOCK_SRV_SOURCE=wrong-volume
! stage_instance_check || fail "drifted srv device accepted"
MOCK_SRV_SOURCE="$SRV_VOLUME"
MOCK_NESTING=false
! stage_instance_check || fail "missing container nesting accepted"
MOCK_NESTING=true

NESTED_E2E_VMS=1
MOCK_INTERCEPTION=allow
MOCK_BPF=true
MOCK_HOST_HAS_KVM=true
MOCK_INSTANCE_DEVICES='srv kvm e2e-vsock e2e-vhost-vsock e2e-tun'
stage_project_check || fail "nested VM project policy rejected"
stage_instance_check || fail "nested VM boundary rejected"
MOCK_BPF=''
! stage_instance_check || fail "missing nested VM BPF interception accepted"
MOCK_BPF=true
MOCK_INTERCEPTION=block
! stage_project_check || fail "blocked nested VM interception policy accepted"
MOCK_INTERCEPTION=allow
MOCK_INSTANCE_DEVICES='srv kvm e2e-vsock e2e-tun'
! stage_instance_check || fail "missing vhost-vsock device accepted"
NESTED_E2E_VMS=0
MOCK_INTERCEPTION=block
MOCK_BPF=''
MOCK_HOST_HAS_KVM=false
MOCK_INSTANCE_DEVICES=srv

mkdir -p "$HOME/.ssh"
printf 'Host %s\n    Port %s\n' "$SSH_HOST" "$SSH_PORT" > "$HOME/.ssh/subyard.config"
if [ "$FORWARD_SSH_AGENT" = 1 ]; then
  printf '    ForwardAgent yes\n' >> "$HOME/.ssh/subyard.config"
fi
printf 'Include subyard.config\n' > "$HOME/.ssh/config"
MOCK_INSTANCE_DEVICES='srv ssh'
reconcile_power_stopped() { return 0; }
stage_ssh_check || fail "matching SSH state rejected"
MOCK_SSH_LISTEN=tcp:127.0.0.1:2299
! stage_ssh_check || fail "drifted SSH proxy accepted"

printf 'ok: init project, instance and SSH probes detect reconcilable drift\n'
