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
E2E_VM_DISK=10GiB
E2E_VM_TTL_MINUTES=15
E2E_VM_BOOT_TIMEOUT=30
E2E_VM_STATE_DIR=$TMP/state
E2E_VM_PUBLIC_DIR=$TMP/public
EOF
export SUBYARD_TEST_VMS_CONFIG="$TMP/test-vms.env"
# shellcheck source=scripts/e2e-lab/worker.sh
. "$ROOT/scripts/e2e-lab/worker.sh"
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

# The privileged L1 worker exposes lifecycle only; agents use the restricted bastion.
if (
  INCUS=bash
  validate_config() { :; }
  main exec 1 -- true
) >"$TMP/removed-exec" 2>&1; then
  fail "privileged worker still exposes direct VM exec"
fi
grep -Fq "unknown command 'exec'" "$TMP/removed-exec" \
  || fail "removed worker exec command has an unclear error"

events="$TMP/events"
ensure_key() { mkdir -p "$STATE_DIR"; : > "$KEY"; : > "$KEY.pub"; printf 'key\n' >> "$events"; }
ensure_project() { printf 'project\n' >> "$events"; }
ensure_vm() { printf 'vm:%s\n' "$1" >> "$events"; }
tighten_project() { printf 'tighten\n' >> "$events"; }
start_vm() { printf 'start:%s\n' "$1" >> "$events"; }
wait_agent() { printf 'agent:%s\n' "$1" >> "$events"; }
record_host_key() { printf 'hostkey:%s\n' "$1" >> "$events"; }
ensure_guest_tools() { printf 'tools:%s\n' "$1" >> "$events"; }
install_managed_guest_keys() { printf 'managed-keys:%s\n' "$1" >> "$events"; }
ensure_peer_trust() { printf 'peer-trust\n' >> "$events"; }
ssh_smoke() { printf 'ssh:%s\n' "$1" >> "$events"; }
restrict_agent_access() { printf 'agent-restrict:%s\n' "$1" >> "$events"; }
enable_agent_access() { printf 'agent-enable\n' >> "$events"; }
cleanup_managed() { printf 'cleanup\n' >> "$events"; }

cmd_up >/dev/null
[ "$(grep -c '^vm:e2e-vm-' "$events")" -eq 2 ] || fail "up did not create exactly two fixed VM names"
[ "$(grep -c '^start:e2e-vm-' "$events")" -eq 2 ] || fail "up did not start exactly two fixed VM names"
grep -Fxq 'ssh:e2e-vm-1' "$events" || fail "VM 1 SSH smoke was skipped"
grep -Fxq 'ssh:e2e-vm-2' "$events" || fail "VM 2 SSH smoke was skipped"
grep -Fxq 'peer-trust' "$events" || fail "mutual VM trust reconciliation was skipped"
grep -Fxq 'agent-enable' "$events" || fail "ready allocation did not publish agent access"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
  inner_incus() { printf '%s\n' "$*" >> "$TMP/tighten-calls"; }
  tighten_project
) || fail "obsolete low-level project policy was not tightened"
grep -Fxq "project unset $PROJECT restricted.virtual-machines.lowlevel" "$TMP/tighten-calls" \
  || fail "project tightening did not remove its obsolete low-level allowance"
grep -Fxq "project set $PROJECT limits.cpu 4" "$TMP/tighten-calls" \
  || fail "project tightening did not reconcile its final CPU limit"
grep -Fxq "project set $PROJECT limits.memory 2GiB" "$TMP/tighten-calls" \
  || fail "project tightening did not reconcile its final memory limit"

# Shrink VM limits before aggregate project limits.
(
  unset -f ensure_project
  . "$ROOT/scripts/e2e-lab/worker.sh"
  MEMORY=768MiB
  project_exists() { return 0; }
  project_marker() { printf '%s\n' "$MARKER"; }
  inner_incus() {
    printf '%s\n' "$*" >> "$TMP/project-shrink-calls"
    case "$*" in
      "list --project $PROJECT -f csv -c n") printf '%s\n' "$PREFIX-1" "$PREFIX-2" ;;
      "project get $PROJECT limits.cpu") printf '4\n' ;;
      "project get $PROJECT limits.memory") printf '2GiB\n' ;;
      "profile device list default --project $PROJECT") printf 'root\neth0\n' ;;
    esac
  }
  ensure_project
) >/dev/null || fail "existing project pre-reconciliation failed"
! grep -Fxq "project set $PROJECT limits.memory 1536MiB" "$TMP/project-shrink-calls" \
  || fail "project memory ceiling was lowered before its VM limits"

# A failed QEMU start must stop `up` immediately. Bash disables implicit errexit inside functions
# used in conditionals, so the worker must propagate this status explicitly rather than print [ok]
# and spend BOOT_TIMEOUT waiting for an agent that can never appear.
if (
  unset -f start_vm
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
# device is named eth0. An initialized owner also has a global address on its nested incusbr0.
# Address discovery must therefore follow the default route instead of counting every interface.
vm_ip_result="$(
  unset -f vm_ip
  . "$ROOT/scripts/e2e-lab/worker.sh"
  inner_incus() {
    case "$1" in
      exec) printf '%s\n' 'default via 10.42.0.1 dev enp5s0 proto dhcp src 10.42.0.7' ;;
      list) printf '%s\n' '[{"state":{"network":{"enp5s0":{"addresses":[{"family":"inet","scope":"global","address":"10.42.0.7"}]},"incusbr0":{"addresses":[{"family":"inet","scope":"global","address":"10.99.0.1"}]},"lo":{"addresses":[{"family":"inet","scope":"local","address":"127.0.0.1"}]}}}}]' ;;
      *) return 90 ;;
    esac
  }
  vm_ip e2e-vm-1
)" || fail "VM IPv4 lookup rejected a renamed guest interface"
[ "$vm_ip_result" = 10.42.0.7 ] || fail "VM IPv4 lookup returned the wrong guest address"
if (
  unset -f vm_ip
  . "$ROOT/scripts/e2e-lab/worker.sh"
  inner_incus() {
    case "$1" in
      exec) printf '%s\n' 'default via 10.42.0.1 dev enp5s0' 'default via 10.43.0.1 dev enp6s0' ;;
      list) printf '%s\n' '[]' ;;
      *) return 90 ;;
    esac
  }
  vm_ip e2e-vm-1
) >/dev/null 2>&1; then
  fail "VM IPv4 lookup accepted multiple default-route interfaces"
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
  . "$ROOT/scripts/e2e-lab/worker.sh"
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
grep -Fq '00-subyard-e2e.conf' "$TMP/guest-ready-calls" \
  || fail "guest SSH key-only policy was not explicitly reconciled"

# Agent access is status plus forwarding to two guest SSH ports.
(
  . "$ROOT/scripts/e2e-lab/worker.sh"
  AGENT_PUBLIC_KEY='ssh-ed25519 AAAAagentfixture controller'
  AGENT_USER="$(id -un)"
  AGENT_HOME="$TMP/agent-home"
  AGENT_AUTHORIZED_KEYS="$AGENT_HOME/.ssh/authorized_keys"
  PUBLIC_DIR="$TMP/agent-public"
  MANIFEST="$PUBLIC_DIR/allocation.tsv"
  CREATED_AT="$TMP/agent-created-at"
  printf '%s\n' "$(date +%s)" > "$CREATED_AT"
  kill_agent_sessions() { :; }

  write_agent_authorized_keys 10.42.0.11 10.42.0.12
  grep -Fq 'restrict,port-forwarding,permitopen="10.42.0.11:22",permitopen="10.42.0.12:22",command="/usr/local/libexec/subyard/test-vms-status"' \
    "$AGENT_AUTHORIZED_KEYS" || fail "agent key does not have the exact two-target bastion policy"
  [ "$(stat -c '%a' "$AGENT_AUTHORIZED_KEYS")" = 600 ] \
    || fail "agent authorized_keys is not private"

  AGENT_PUBLIC_KEY='ssh-ed25519 BBBBagentfixture rotated'
  write_agent_authorized_keys 10.42.0.11 10.42.0.12
  grep -Fq 'ssh-ed25519 BBBBagentfixture' "$AGENT_AUTHORIZED_KEYS" \
    || fail "agent key rotation was not applied"
  ! grep -Fq 'ssh-ed25519 AAAAagentfixture' "$AGENT_AUTHORIZED_KEYS" \
    || fail "agent key rotation retained the old key"
  rotated_hash="$(sha256sum "$AGENT_AUTHORIZED_KEYS")"
  write_agent_authorized_keys 10.42.0.11 10.42.0.12
  [ "$(sha256sum "$AGENT_AUTHORIZED_KEYS")" = "$rotated_hash" ] \
    || fail "agent key reconciliation is not idempotent"

  write_manifest ready ready \
    10.42.0.11 'ssh-ed25519 AAAAhost1111' 10.42.0.12 'ssh-ed25519 AAAAhost2222'
  status_output="$(SUBYARD_E2E_ALLOCATION_MANIFEST="$MANIFEST" \
    SSH_ORIGINAL_COMMAND='id' sh "$ROOT/scripts/e2e-lab/status.sh")"
  printf '%s\n' "$status_output" | grep -Fxq $'vm\t1\te2e-vm-1\t10.42.0.11\tssh-ed25519\tAAAAhost1111' \
    || fail "forced status lost VM1 target or host-key pin"
  [ "$(stat -c '%a' "$MANIFEST")" = 644 ] || fail "public allocation snapshot mode drifted"

  restrict_agent_access operator-down
  ! grep -Fq 'port-forwarding' "$AGENT_AUTHORIZED_KEYS" \
    || fail "down allocation retained SSH forwarding"
  grep -Fxq $'state\tdown' "$MANIFEST" || fail "down allocation was not published"
) || exit 1

# Cross-owner checks use VM-local synthetic keys. The trusted inner control plane exchanges only
# public client and host keys, then proves both directions without TOFU or a shared private key.
(
  unset -f ensure_peer_trust
  . "$ROOT/scripts/e2e-lab/worker.sh"
  vm_ip() { case "$1" in e2e-vm-1) printf '10.42.0.11\n' ;; *) printf '10.42.0.12\n' ;; esac; }
  ensure_guest_peer_key() { case "$1" in e2e-vm-1) printf 'ssh-ed25519 AAAA1111\n' ;; *) printf 'ssh-ed25519 AAAA2222\n' ;; esac; }
  guest_host_public_key() { case "$1" in e2e-vm-1) printf 'ssh-ed25519 BBBB1111\n' ;; *) printf 'ssh-ed25519 BBBB2222\n' ;; esac; }
  install_guest_peer_trust() { printf 'install:%s:%s:%s:%s\n' "$@" >> "$TMP/peer-events"; }
  peer_ssh_smoke() { printf 'smoke:%s:%s\n' "$@" >> "$TMP/peer-events"; }
  ensure_peer_trust
) >/dev/null || fail "mutual VM trust reconciliation failed"
grep -Fxq 'install:e2e-vm-1:10.42.0.12:ssh-ed25519 AAAA2222:ssh-ed25519 BBBB2222' \
  "$TMP/peer-events" || fail "VM1 did not trust VM2 public client and host keys"
grep -Fxq 'install:e2e-vm-2:10.42.0.11:ssh-ed25519 AAAA1111:ssh-ed25519 BBBB1111' \
  "$TMP/peer-events" || fail "VM2 did not trust VM1 public client and host keys"
grep -Fxq 'smoke:e2e-vm-1:10.42.0.12' "$TMP/peer-events" \
  || fail "VM1-to-VM2 SSH smoke was skipped"
grep -Fxq 'smoke:e2e-vm-2:10.42.0.11' "$TMP/peer-events" \
  || fail "VM2-to-VM1 SSH smoke was skipped"

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
  . "$ROOT/scripts/e2e-lab/worker.sh"
  INCUS="$TMP/cleanup-incus"
  cleanup_managed 1
) >/dev/null || fail "guarded non-interactive cleanup failed"
grep -Fxq "project delete $PROJECT" "$TMP/cleanup-calls" \
  || fail "cleanup did not normally delete the empty managed project"
! grep -Fq "project delete $PROJECT --force" "$TMP/cleanup-calls" \
  || fail "cleanup used Incus 6.0's interactive forced project deletion"

cleanup_managed() { printf 'expired-cleanup\n' >> "$events"; }
project_exists() { return 0; }
project_marker() { printf '%s\n' "$MARKER"; }
mkdir -p "$STATE_DIR"
printf '%s\n' "$(( $(date +%s) - TTL_MINUTES * 60 - 1 ))" > "$CREATED_AT"
cmd_gc
grep -Fxq expired-cleanup "$events" || fail "expired lab was not cleaned"

# The provisioner is streamed into L1 through `bash -s`; under `set -u`, its source guard must
# accept an empty BASH_SOURCE instead of failing before the inner bootstrap starts.
source_guard="$(sed -n '/^\[ "${BASH_SOURCE\[0\]:-\$0}" = "\$0" \] || return 0$/p' \
  "$ROOT/scripts/e2e-lab/provision.sh")"
[ -n "$source_guard" ] || fail "inner provisioner has no stdin-safe source guard"
printf '%s\n' "$source_guard" | bash -u -s \
  || fail "inner provisioner source guard rejected bash -s execution"
! grep -Eq 'usermod[[:space:]]+-aG[[:space:]]+(incus-admin|yard)' \
  "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "inner provisioner still grants dev access to privileged inner groups"
grep -Fq 'iifname "incusbr0" drop' "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "inner provisioner does not block guest-initiated access to L1"
grep -Fq 'PasswordAuthentication no' "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "bastion provisioner does not disable password authentication"
grep -Fq 'apt-get install -y -qq --no-install-recommends' \
  "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "inner VM backend installs optional QEMU desktop packages"
grep -Fq 'apt-get clean' "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "inner VM backend leaves the package cache on the small disposable disk"
grep -Fq 'run_with_progress "installing inner Incus and QEMU"' \
  "$ROOT/scripts/e2e-lab/provision.sh" \
  && grep -Fq 'still working, %ss elapsed' "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "inner VM backend package installation has no periodic progress"
grep -Fq 'install -d -m 0750 -o root -g "$primary" "$home/.ssh"' \
  "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "bastion authorized-key directory is not root-owned and account-readable"
grep -Fq 'chown root:"$primary" "$home/.ssh/authorized_keys"' \
  "$ROOT/scripts/e2e-lab/provision.sh" \
  || fail "bastion authorized-key file is not root-owned and account-readable"

if SUBYARD_E2E_LEGACY_FIXTURE=1 \
  bash "$ROOT/dev/e2e/seed-test-vms-legacy-state.sh" fixture-project fixture-instance \
  >/dev/null 2>&1; then
  fail "legacy upgrade fixture ran outside disposable VM1"
fi
grep -Fq 'user.subyard.managed' "$ROOT/dev/e2e/seed-test-vms-legacy-state.sh" \
  || fail "legacy upgrade fixture does not verify candidate ownership"

# A first inner-Incus bootstrap must recover from the nested AppArmor denial of dnsmasq's syslog
# socket in the same run, then remain idempotent on reconciliation.
INNER_FIXTURE="$TMP/inner-incus"
mkdir -p "$INNER_FIXTURE"
export INNER_FIXTURE
# shellcheck source=scripts/e2e-lab/provision.sh
. "$ROOT/scripts/e2e-lab/provision.sh"

E2E_VM_STATE_DIR="$TMP/legacy-test-vms-state"
mkdir -p "$E2E_VM_STATE_DIR"
chmod 2770 "$E2E_VM_STATE_DIR"
printf 'legacy\n' > "$E2E_VM_STATE_DIR/worker-key"
chmod 0660 "$E2E_VM_STATE_DIR/worker-key"
reconcile_test_vm_state_directory
[ "$(stat -c '%a' "$E2E_VM_STATE_DIR")" = 700 ] \
  || fail "legacy test-vms state directory retained its setgid boundary"
[ "$(stat -c '%a' "$E2E_VM_STATE_DIR/worker-key")" = 600 ] \
  || fail "legacy test-vms state file retained group access"

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
