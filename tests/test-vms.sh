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
E2E_VM_DISK=30GiB
E2E_VM_TTL_MINUTES=15
E2E_VM_BOOT_TIMEOUT=30
E2E_VM_STATE_DIR=$TMP/state
EOF
export SUBYARD_TEST_VMS_CONFIG="$TMP/test-vms.env"
# shellcheck source=scripts/test-vms-inner.sh
. "$ROOT/scripts/test-vms-inner.sh"
ASSUME_YES=1

# The worker is itself streamed through `incus exec`. No inner Incus subcommand may inherit that
# control stream, because create/update commands interpret stdin as YAML and otherwise wait forever.
cat > "$TMP/stdin-incus" <<'EOF'
#!/usr/bin/env bash
if IFS= read -r leaked; then
  printf 'consumed:%s\n' "$leaked"
  exit 65
fi
printf 'stdin-closed\n'
EOF
chmod +x "$TMP/stdin-incus"
original_incus="$INCUS"
INCUS="$TMP/stdin-incus"
stdin_result="$(printf 'future worker input\n' | inner_incus project create fixture)" \
  || fail "inner Incus wrapper failed with an inherited control stream"
[ "$stdin_result" = stdin-closed ] || fail "inner Incus wrapper consumed its caller's stdin"
INCUS="$original_incus"

E2E_PROGRESS_INTERVAL=0.01
progress_result="$(run_with_progress "slow fixture operation" bash -c 'sleep 0.04')"
unset E2E_PROGRESS_INTERVAL
printf '%s\n' "$progress_result" | grep -Fq 'slow fixture operation (still working,' \
  || fail "long operation emitted no periodic progress"

events="$TMP/events"
ensure_key() { mkdir -p "$STATE_DIR"; : > "$KEY"; : > "$KEY.pub"; printf 'key\n' >> "$events"; }
ensure_project() { printf 'project\n' >> "$events"; }
ensure_vm() { printf 'vm:%s\n' "$1" >> "$events"; }
tighten_project() { printf 'tighten\n' >> "$events"; }
start_vm() { printf 'start:%s\n' "$1" >> "$events"; }
wait_agent() { printf 'agent:%s\n' "$1" >> "$events"; }
record_host_key() { printf 'hostkey:%s\n' "$1" >> "$events"; }
ssh_smoke() { printf 'ssh:%s\n' "$1" >> "$events"; }
cleanup_managed() { printf 'cleanup\n' >> "$events"; }

cmd_up >/dev/null
[ "$(grep -c '^vm:e2e-vm-' "$events")" -eq 2 ] || fail "up did not create exactly two fixed VM names"
[ "$(grep -c '^start:e2e-vm-' "$events")" -eq 2 ] || fail "up did not start exactly two fixed VM names"
grep -Fxq 'ssh:e2e-vm-1' "$events" || fail "VM 1 SSH smoke was skipped"
grep -Fxq 'ssh:e2e-vm-2' "$events" || fail "VM 2 SSH smoke was skipped"
! grep -Fxq cleanup "$events" || fail "successful up invoked failure cleanup"

: > "$events"
ensure_vm() {
  printf 'vm:%s\n' "$1" >> "$events"
  [ "$1" != e2e-vm-2 ] || return 23
}
if (cmd_up) >/dev/null 2>&1; then fail "partial VM creation was reported as success"; fi
! grep -Fxq cleanup "$events" || fail "failed up changed operator-owned allocation state"
[ -s "$FAILURE_LOG" ] || fail "failed up preserved no diagnostic snapshot"
grep -Fxq 'worker_exit=23' "$FAILURE_LOG" || fail "failure diagnostics lost the worker exit status"

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

# The fixed project must not allow arbitrary low-level VM configuration. AppArmor compatibility is
# handled by the trusted inner daemon, outside the restricted disposable-VM project.
cat > "$TMP/policy-incus" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/policy-calls'
case "\$*" in
  "project show $PROJECT") exit 0 ;;
  "project get $PROJECT user.subyard.managed") printf '%s\n' '$MARKER' ;;
  "list --project $PROJECT -f csv -c n") exit 0 ;;
  "profile device list default --project $PROJECT") printf 'root\neth0\n' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/policy-incus"
(
  unset -f ensure_project
  . "$ROOT/scripts/test-vms-inner.sh"
  INCUS="$TMP/policy-incus"
  ensure_project
) >/dev/null || fail "managed partial project policy reconciliation failed"
! grep -Fq 'restricted.virtual-machines.lowlevel=allow' "$TMP/policy-calls" \
  || fail "new restricted VM project enabled low-level configuration"
! grep -Fq "project set $PROJECT restricted.virtual-machines.lowlevel allow" "$TMP/policy-calls" \
  || fail "managed VM project retained its obsolete low-level allowance"
! grep -Fq 'profile set default raw.apparmor' "$TMP/policy-calls" \
  || fail "VM project added a raw AppArmor profile override"

(
  unset -f tighten_project
  . "$ROOT/scripts/test-vms-inner.sh"
  inner_incus() { printf '%s\n' "$*" >> "$TMP/tighten-calls"; }
  tighten_project
) || fail "obsolete low-level project policy was not tightened"
grep -Fxq "project unset $PROJECT restricted.virtual-machines.lowlevel" "$TMP/tighten-calls" \
  || fail "project tightening did not remove its obsolete low-level allowance"

# A failed QEMU start must stop `up` immediately. Bash disables implicit errexit inside functions
# used in conditionals, so the worker must propagate this status explicitly rather than print [ok]
# and spend BOOT_TIMEOUT waiting for an agent that can never appear.
if (
  unset -f start_vm
  . "$ROOT/scripts/test-vms-inner.sh"
  inner_incus() {
    printf '%s\n' "$*" >> "$TMP/vm-policy-calls"
    case "$*" in
      "list e2e-vm-1 --project $PROJECT -f csv -c s") printf 'STOPPED\n' ;;
      *) return 90 ;;
    esac
  }
  run_with_progress() { return 29; }
  start_vm e2e-vm-1
) >/dev/null 2>&1; then
  fail "failed QEMU start was reported as success"
fi

# Upgrade reconciliation removes the old per-VM raw policy before project tightening.
(
  unset -f ensure_vm
  . "$ROOT/scripts/test-vms-inner.sh"
  vm_exists() { return 0; }
  vm_marker() { printf '%s\n' "$MARKER"; }
  inner_incus() {
    printf '%s\n' "$*" >> "$TMP/vm-upgrade-calls"
    case "$*" in
      "list e2e-vm-1 --project $PROJECT -f csv -c t") printf 'VIRTUAL-MACHINE\n' ;;
      "config get e2e-vm-1 raw.apparmor --project $PROJECT") printf 'legacy-rule\n' ;;
      config\ set*|"config unset e2e-vm-1 raw.apparmor --project $PROJECT") return 0 ;;
      *) return 90 ;;
    esac
  }
  ensure_vm e2e-vm-1
) >/dev/null || fail "legacy VM AppArmor reconciliation failed"
grep -Fxq "config unset e2e-vm-1 raw.apparmor --project $PROJECT" "$TMP/vm-upgrade-calls" \
  || fail "legacy per-VM AppArmor override was not removed"

# VM images use predictable guest interface names (for example enp5s0), even though the Incus
# device is named eth0. Address discovery must follow network state instead of assuming the guest
# kept the device name, and it must reject an ambiguous multi-network result.
vm_ip_result="$(
  unset -f vm_ip
  . "$ROOT/scripts/test-vms-inner.sh"
  inner_incus() {
    printf '%s\n' '[{"state":{"network":{"enp5s0":{"addresses":[{"family":"inet","scope":"global","address":"10.42.0.7"}]},"lo":{"addresses":[{"family":"inet","scope":"local","address":"127.0.0.1"}]}}}}]'
  }
  vm_ip e2e-vm-1
)" || fail "VM IPv4 lookup rejected a renamed guest interface"
[ "$vm_ip_result" = 10.42.0.7 ] || fail "VM IPv4 lookup returned the wrong guest address"
if (
  unset -f vm_ip
  . "$ROOT/scripts/test-vms-inner.sh"
  inner_incus() {
    printf '%s\n' '[{"state":{"network":{"enp5s0":{"addresses":[{"family":"inet","scope":"global","address":"10.42.0.7"}]},"enp6s0":{"addresses":[{"family":"inet","scope":"global","address":"10.43.0.7"}]}}}}]'
  }
  vm_ip e2e-vm-1
) >/dev/null 2>&1; then
  fail "VM IPv4 lookup accepted an ambiguous multi-network result"
fi

# Debian 13 OpenSSH rejects public keys for a shadow-locked account. Cloud-init and reconciliation
# must make the synthetic user key-login capable without enabling any usable password.
cloud_fixture="$(cloud_config)"
printf '%s\n' "$cloud_fixture" | grep -Fxq '    lock_passwd: false' \
  || fail "cloud-init leaves the synthetic VM user locked"
printf '%s\n' "$cloud_fixture" | grep -Fxq '    passwd: x' \
  || fail "cloud-init did not install the deliberately invalid password marker"
printf '%s\n' "$cloud_fixture" | grep -Fxq 'ssh_pwauth: false' \
  || fail "cloud-init enabled SSH password authentication"

(
  unset -f wait_agent
  . "$ROOT/scripts/test-vms-inner.sh"
  inner_incus() {
    printf '%s\n' "$*" >> "$TMP/guest-ready-calls"
    case "$*" in
      "exec e2e-vm-1 --project $PROJECT -- passwd --status dev") printf 'dev P fixture\n' ;;
      "exec e2e-vm-1 --project $PROJECT -- sshd -T") printf 'passwordauthentication no\n' ;;
    esac
  }
  run_with_progress() { shift; "$@"; }
  wait_agent e2e-vm-1
) >/dev/null || fail "key-only guest account reconciliation failed"
grep -Fxq "exec e2e-vm-1 --project $PROJECT -- usermod --password x dev" "$TMP/guest-ready-calls" \
  || fail "existing VM user was not unlocked for public-key login"

# Operator-owned guarded cleanup first deletes the two known instances, then performs a normal
# deletion of the empty project. Incus 6.0's `project delete --force` prompts even on closed stdin
# and is unsuitable for this worker.
cat > "$TMP/cleanup-incus" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/cleanup-calls'
case "\$*" in
  "project show $PROJECT") exit 0 ;;
  "project get $PROJECT user.subyard.managed") printf '%s\n' '$MARKER' ;;
  "list --project $PROJECT -f csv -c n") printf '%s\n' '$PREFIX-1' '$PREFIX-2' ;;
  "info $PREFIX-1 --project $PROJECT"|"info $PREFIX-2 --project $PROJECT") exit 0 ;;
  "config get $PREFIX-1 user.subyard.managed --project $PROJECT"|\
  "config get $PREFIX-2 user.subyard.managed --project $PROJECT") printf '%s\n' '$MARKER' ;;
  "delete $PREFIX-1 --project $PROJECT --force"|\
  "delete $PREFIX-2 --project $PROJECT --force"|\
  "project delete $PROJECT") exit 0 ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$TMP/cleanup-incus"
(
  . "$ROOT/scripts/test-vms-inner.sh"
  INCUS="$TMP/cleanup-incus"
  cleanup_managed 1
) >/dev/null || fail "guarded non-interactive cleanup failed"
grep -Fxq "project delete $PROJECT" "$TMP/cleanup-calls" \
  || fail "cleanup did not normally delete the empty managed project"
! grep -Fq "project delete $PROJECT --force" "$TMP/cleanup-calls" \
  || fail "cleanup used Incus 6.0's interactive forced project deletion"

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

# The provisioner is streamed into L1 through `bash -s`; under `set -u`, its source guard must
# accept an empty BASH_SOURCE instead of failing before the inner bootstrap starts.
source_guard="$(sed -n '/^\[ "${BASH_SOURCE\[0\]:-\$0}" = "\$0" \] || return 0$/p' \
  "$ROOT/scripts/provision-test-vms-inner.sh")"
[ -n "$source_guard" ] || fail "inner provisioner has no stdin-safe source guard"
printf '%s\n' "$source_guard" | bash -u -s \
  || fail "inner provisioner source guard rejected bash -s execution"

# A first inner-Incus bootstrap must recover from the nested AppArmor denial of dnsmasq's syslog
# socket in the same run, then remain idempotent on reconciliation.
INNER_FIXTURE="$TMP/inner-incus"
mkdir -p "$INNER_FIXTURE"
export INNER_FIXTURE
# shellcheck source=scripts/provision-test-vms-inner.sh
. "$ROOT/scripts/provision-test-vms-inner.sh"

# Incus 6.0 plus AppArmor 4.1 userspace on a 6.8 outer kernel rejects QEMU AF_UNIX rules because
# of a parser/kernel ABI mismatch. The compatibility switch applies only to the inner daemon and
# must restart it once when installed, not on every init reconciliation.
export SUBYARD_INNER_INCUS_APPARMOR_DROPIN="$TMP/incus.service.d/subyard-nested-e2e.conf"
systemctl() {
  printf '%s\n' "$*" >> "$TMP/systemctl-calls"
  case "$*" in 'is-active --quiet incus.service') return 0 ;; esac
}
reconcile_inner_apparmor_compat
reconcile_inner_apparmor_compat
grep -Fxq 'Environment=INCUS_SECURITY_APPARMOR=false' "$SUBYARD_INNER_INCUS_APPARMOR_DROPIN" \
  || fail "inner Incus AppArmor compatibility drop-in was not installed"
[ "$(grep -c '^restart incus.service$' "$TMP/systemctl-calls")" -eq 1 ] \
  || fail "idempotent AppArmor compatibility reconciliation restarted Incus more than once"
unset -f systemctl

install() {
  [ "${*: -1}" = /srv/incus-e2e/storage ] || command install "$@"
}
incus() {
  local leaked
  if IFS= read -r leaked; then
    printf '%s\n' "$leaked" > "$INNER_FIXTURE/consumed-stdin"
    return 65
  fi
  printf '%s\n' "$*" >> "$INNER_FIXTURE/calls"
  case "$*" in
    'storage show default --project default') [ -f "$INNER_FIXTURE/storage" ] ;;
    'storage create default dir source=/srv/incus-e2e/storage --project default')
      : > "$INNER_FIXTURE/storage" ;;
    'network show incusbr0 --project default') [ -f "$INNER_FIXTURE/network" ] ;;
    'network create incusbr0 ipv4.address=auto ipv6.address=none --project default')
      printf 'dnsmasq: cannot open log : Permission denied\n'; return 3 ;;
    'network create incusbr0 ipv4.address=auto ipv6.address=none raw.dnsmasq=log-facility=/var/lib/incus/networks/incusbr0/dnsmasq.log --project default')
      : > "$INNER_FIXTURE/network" ;;
    'profile show default --project default') [ -f "$INNER_FIXTURE/profile" ] ;;
    'profile create default --project default') : > "$INNER_FIXTURE/profile" ;;
    'profile device list default --project default')
      [ -f "$INNER_FIXTURE/root" ] && printf 'root\n'
      [ -f "$INNER_FIXTURE/eth0" ] && printf 'eth0\n'
      return 0
      ;;
    'profile device add default root disk pool=default path=/ --project default')
      : > "$INNER_FIXTURE/root" ;;
    'profile device add default eth0 nic network=incusbr0 --project default')
      : > "$INNER_FIXTURE/eth0" ;;
    *) return 64 ;;
  esac
}
printf 'cat > /etc/systemd/system/subyard-test-vms-gc.service\n' | reconcile_inner_incus
reconcile_inner_incus
[ ! -e "$INNER_FIXTURE/consumed-stdin" ] \
  || fail "inner Incus CLI consumed the remaining streamed provisioner"
[ "$(grep -c '^storage create ' "$INNER_FIXTURE/calls")" -eq 1 ] \
  || fail "inner storage bootstrap was not idempotent"
[ "$(grep -c '^network create ' "$INNER_FIXTURE/calls")" -eq 2 ] \
  || fail "inner network bootstrap did not perform one file-log fallback"
[ "$(grep -c '^profile device add ' "$INNER_FIXTURE/calls")" -eq 2 ] \
  || fail "inner default profile bootstrap was not idempotent"

printf 'ok: nested Incus bootstrap and test-vms lifecycle are idempotent and ownership-guarded\n'
