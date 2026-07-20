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
MOCK_SSH_LISTEN="tcp:127.0.0.1:$SSH_PORT"
incus() {
  case "${1:-} ${2:-} ${3:-}" in
    'project show '* | 'info yard '*) return 0 ;;
    'project get subyard')
      case "${4:-}" in
        restricted) printf '%s\n' "$MOCK_RESTRICTED" ;;
        restricted.containers.nesting) printf 'allow\n' ;;
        restricted.containers.privilege) printf 'unprivileged\n' ;;
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
      else
        case "${6:-}" in
          source) printf '%s\n' "$MOCK_SRV_SOURCE" ;;
          path) printf '/srv\n' ;;
          pool) printf '%s\n' "$SRV_POOL" ;;
        esac
      fi ;;
    'config get yard') printf '%s\n' "$MOCK_NESTING" ;;
  esac
}

stage_project_check || fail "matching project policy rejected"
MOCK_RESTRICTED=false
! stage_project_check || fail "project policy drift accepted"
MOCK_RESTRICTED=true
MOCK_PROJECT_DEVICES=root
! stage_project_check || fail "missing project NIC accepted"
MOCK_PROJECT_DEVICES='root eth0'

stage_instance_check || fail "matching instance state rejected"
MOCK_INSTANCE_DEVICES=''
! stage_instance_check || fail "missing srv device accepted"
MOCK_INSTANCE_DEVICES=srv
MOCK_SRV_SOURCE=wrong-volume
! stage_instance_check || fail "drifted srv device accepted"
MOCK_SRV_SOURCE="$SRV_VOLUME"
MOCK_NESTING=false
! stage_instance_check || fail "missing container nesting accepted"

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
