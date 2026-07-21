#!/usr/bin/env bash
# Host-free contracts for the fixed two-VM lifecycle, ownership guard and TTL cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TMP/test-vms.env" <<EOF
NESTED_E2E_VMS=1
DEV_USER=$(id -un)
E2E_VM_IMAGE=images:debian/13/cloud
E2E_VM_CPU=2
E2E_VM_MEMORY=1GiB
E2E_VM_TTL_MINUTES=15
E2E_VM_BOOT_TIMEOUT=30
E2E_VM_STATE_DIR=$TMP/state
EOF
export SUBYARD_TEST_VMS_CONFIG="$TMP/test-vms.env"
# shellcheck source=scripts/test-vms-inner.sh
. "$ROOT/scripts/test-vms-inner.sh"
ASSUME_YES=1

events="$TMP/events"
ensure_key() { mkdir -p "$STATE_DIR"; : > "$KEY"; : > "$KEY.pub"; printf 'key\n' >> "$events"; }
ensure_project() { printf 'project\n' >> "$events"; }
ensure_vm() { printf 'vm:%s\n' "$1" >> "$events"; }
wait_agent() { printf 'agent:%s\n' "$1" >> "$events"; }
record_host_key() { printf 'hostkey:%s\n' "$1" >> "$events"; }
ssh_smoke() { printf 'ssh:%s\n' "$1" >> "$events"; }
cleanup_managed() { printf 'cleanup\n' >> "$events"; }

cmd_up >/dev/null
[ "$(grep -c '^vm:e2e-vm-' "$events")" -eq 2 ] || fail "up did not create exactly two fixed VM names"
grep -Fxq 'ssh:e2e-vm-1' "$events" || fail "VM 1 SSH smoke was skipped"
grep -Fxq 'ssh:e2e-vm-2' "$events" || fail "VM 2 SSH smoke was skipped"
! grep -Fxq cleanup "$events" || fail "successful up invoked failure cleanup"

: > "$events"
ensure_vm() {
  printf 'vm:%s\n' "$1" >> "$events"
  [ "$1" != e2e-vm-2 ] || return 23
}
if (cmd_up >/dev/null 2>&1); then fail "partial VM creation was reported as success"; fi
grep -Fxq cleanup "$events" || fail "partial VM creation did not invoke cleanup"

if (
  unset -f cleanup_managed
  . "$ROOT/scripts/test-vms-inner.sh"
  project_exists() { return 0; }
  project_marker() { printf 'foreign\n'; }
  cleanup_managed 1
) >/dev/null 2>&1; then
  fail "cleanup accepted an unmarked project"
fi

cat > "$TMP/foreign-incus" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "project show $PROJECT") exit 0 ;;
  "project get $PROJECT user.subyard.managed") printf '%s\\n' '$MARKER' ;;
  "list --project $PROJECT -f csv -c n") printf 'unexpected-vm\\n' ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$TMP/foreign-incus"
if (
  unset -f ensure_project
  . "$ROOT/scripts/test-vms-inner.sh"
  INCUS="$TMP/foreign-incus"
  ensure_project
) >/dev/null 2>&1; then
  fail "up reconciliation accepted an unexpected project instance"
fi

if (
  vm_exists() { return 0; }
  vm_marker() { printf 'foreign\n'; }
  require_managed_vm e2e-vm-1
) >/dev/null 2>&1; then
  fail "SSH/exec ownership guard accepted an unmarked VM"
fi

cleanup_managed() { printf 'expired-cleanup\n' >> "$events"; }
project_exists() { return 0; }
project_marker() { printf '%s\n' "$MARKER"; }
mkdir -p "$STATE_DIR"
printf '%s\n' "$(( $(date +%s) - TTL_MINUTES * 60 - 1 ))" > "$CREATED_AT"
cmd_gc
grep -Fxq expired-cleanup "$events" || fail "expired lab was not cleaned"

[ "$(vm_name 1)" = e2e-vm-1 ] && [ "$(vm_name 2)" = e2e-vm-2 ] \
  || fail "VM selectors drifted"
if (vm_name 3) >/dev/null 2>&1; then fail "unsafe VM selector was accepted"; fi

printf 'ok: test-vms lifecycle is fixed to two marked VMs with failure and TTL cleanup\n'
