#!/usr/bin/env bash
# test-vms-inner.sh — trusted L1 worker for two disposable nested Incus VMs.
# Installed inside an opt-in container yard; never talks to the L0 Incus socket.
set -euo pipefail

CONFIG_FILE="${SUBYARD_TEST_VMS_CONFIG:-/etc/subyard/test-vms.env}"
# shellcheck disable=SC1090 # root-owned runtime config; tests inject a temporary equivalent.
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ENABLED="${NESTED_E2E_VMS:-0}"
PROJECT="${E2E_VM_PROJECT:-subyard-e2e-vms}"
PREFIX="${E2E_VM_PREFIX:-e2e-vm}"
IMAGE="${E2E_VM_IMAGE:-images:debian/13/cloud}"
CPU="${E2E_VM_CPU:-2}"
MEMORY="${E2E_VM_MEMORY:-4GiB}"
DISK="${E2E_VM_DISK:-30GiB}"
TTL_MINUTES="${E2E_VM_TTL_MINUTES:-240}"
BOOT_TIMEOUT="${E2E_VM_BOOT_TIMEOUT:-300}"
DEV_USER="${DEV_USER:-dev}"
STATE_DIR="${E2E_VM_STATE_DIR:-/var/lib/subyard/test-vms}"
MARKER="test-vms-v1"
INCUS="${SUBYARD_INNER_INCUS:-incus}"

KEY="$STATE_DIR/id_ed25519"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
CREATED_AT="$STATE_DIR/created-at"
FAILURE_LOG="$STATE_DIR/last-failure.log"
ASSUME_YES=0

die() { printf 'test-vms: %s\n' "$*" >&2; exit 1; }
info() { printf '  [ .. ] %s\n' "$*"; }
ok() { printf '  [ ok ] %s\n' "$*"; }

# Incus create/set commands may consume YAML from stdin. The worker itself is reached through
# `incus exec`, so inheriting that stream can make a command wait forever for input that will never
# arrive. Every inner control-plane call therefore gets a closed input stream.
inner_incus() { "$INCUS" "$@" </dev/null; }

# Long image downloads, VM starts and guest initialization must remain observable even when this
# worker is reached through a non-interactive exec. Periodic lines are intentional: unlike a TTY
# spinner they survive SSH/Incus forwarding and leave useful timings in CI logs.
run_with_progress() {
  local label="$1" interval="${E2E_PROGRESS_INTERVAL:-10}" ticker rc started=$SECONDS
  shift
  info "$label"
  (
    while sleep "$interval"; do
      printf '  [ .. ] %s (still working, %ss elapsed)\n' "$label" "$((SECONDS - started))"
    done
  ) &
  ticker=$!
  if "$@"; then rc=0; else rc=$?; fi
  kill "$ticker" 2>/dev/null || true
  wait "$ticker" 2>/dev/null || true
  return "$rc"
}

usage() {
  cat <<'EOF'
Usage: yard test-vms <command> [args]

  up                  create/start both disposable VMs and verify SSH
  status              show VM state, address and TTL
  ssh <1|2>           open an interactive SSH session as dev (sudo is passwordless)
  exec <1|2> -- CMD   run a command over the pinned SSH connection
  down                delete both VMs, their project and synthetic SSH key

Mutating commands ask once; --yes is for automation. The TTL cleaner removes an
expired managed lab even if the initiating session disappears.
EOF
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local answer
  [ -t 0 ] || die "confirmation required (re-run with --yes for automation)"
  read -r -p "  Proceed? [y/N] " answer
  case "$answer" in y | Y | yes | YES | Yes) return 0 ;; *) die "aborted" ;; esac
}

validate_config() {
  [ "$ENABLED" = 1 ] || die "nested E2E VMs are disabled; set NESTED_E2E_VMS=1 on the yard owner and run 'yard init'"
  case "$PROJECT" in '' | -* | *[!a-z0-9-]*) die "unsafe E2E_VM_PROJECT '$PROJECT'" ;; esac
  case "$PREFIX" in '' | -* | *[!a-z0-9-]*) die "unsafe E2E_VM_PREFIX '$PREFIX'" ;; esac
  [[ "$CPU" =~ ^[1-9][0-9]*$ ]] || die "E2E_VM_CPU must be a positive integer"
  [[ "$MEMORY" =~ ^[1-9][0-9]*(MiB|GiB)$ ]] || die "E2E_VM_MEMORY must use MiB or GiB"
  [[ "$DISK" =~ ^[1-9][0-9]*(MiB|GiB)$ ]] || die "E2E_VM_DISK must use MiB or GiB"
  local disk_mib
  case "$DISK" in
    *GiB) disk_mib=$(( ${DISK%GiB} * 1024 )) ;;
    *MiB) disk_mib=${DISK%MiB} ;;
  esac
  [ "$disk_mib" -ge 24576 ] || die "E2E_VM_DISK must be at least 24GiB"
  case "$IMAGE" in '' | -* | *[!A-Za-z0-9._:/@+-]*) die "unsafe E2E_VM_IMAGE '$IMAGE'" ;; esac
  [[ "$TTL_MINUTES" =~ ^[0-9]+$ ]] && [ "$TTL_MINUTES" -ge 15 ] && [ "$TTL_MINUTES" -le 1440 ] \
    || die "E2E_VM_TTL_MINUTES must be from 15 to 1440"
  [[ "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$BOOT_TIMEOUT" -ge 30 ] && [ "$BOOT_TIMEOUT" -le 1800 ] \
    || die "E2E_VM_BOOT_TIMEOUT must be from 30 to 1800"
}

vm_name() {
  case "${1:-}" in 1 | 2) printf '%s-%s\n' "$PREFIX" "$1" ;; *) die "VM selector must be 1 or 2" ;; esac
}

project_exists() { inner_incus project show "$PROJECT" >/dev/null 2>&1; }
project_marker() { inner_incus project get "$PROJECT" user.subyard.managed 2>/dev/null || true; }
vm_exists() { inner_incus info "$1" --project "$PROJECT" >/dev/null 2>&1; }
vm_marker() { inner_incus config get "$1" user.subyard.managed --project "$PROJECT" 2>/dev/null || true; }

require_managed_vm() {
  vm_exists "$1" || die "$1 is not up"
  [ "$(vm_marker "$1")" = "$MARKER" ] || die "VM '$1' is not Subyard-managed"
}

ensure_state_dir() {
  local group=yard
  getent group "$group" >/dev/null 2>&1 || group="$(id -gn "$DEV_USER" 2>/dev/null || id -gn)"
  if [ "$(id -u)" = 0 ]; then
    install -d -m 2770 -o root -g "$group" "$STATE_DIR"
  else
    [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ] \
      || die "state directory is not writable; re-run yard init on the owner host"
  fi
}

ensure_key() {
  ensure_state_dir
  if [ ! -s "$KEY" ] || [ ! -s "$KEY.pub" ]; then
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C subyard-test-vms -f "$KEY"
  fi
  if [ "$(id -u)" = 0 ] && id -u "$DEV_USER" >/dev/null 2>&1; then
    chown "$DEV_USER" "$KEY" "$KEY.pub"
  fi
  chmod 0600 "$KEY"; chmod 0644 "$KEY.pub"
}

ensure_project() {
  local total_cpu memory_number memory_unit total_memory name names
  total_cpu=$((CPU * 2))
  memory_unit="${MEMORY##*[0-9]}"; memory_number="${MEMORY%$memory_unit}"
  total_memory="$((memory_number * 2))$memory_unit"
  if project_exists; then
    [ "$(project_marker)" = "$MARKER" ] \
      || die "project '$PROJECT' exists without the Subyard marker; refusing to modify it"
    names="$(inner_incus list --project "$PROJECT" -f csv -c n)" || return
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in
        "$PREFIX-1" | "$PREFIX-2") ;;
        *) die "unexpected instance blocks reconciliation: $name" ;;
      esac
    done <<<"$names"
  else
    run_with_progress "creating inner Incus project '$PROJECT'" inner_incus project create "$PROJECT" \
      -c features.images=false \
      -c user.subyard.managed="$MARKER" \
      -c limits.instances=2 \
      -c limits.virtual-machines=2 \
      -c limits.cpu="$total_cpu" \
      -c limits.memory="$total_memory" \
      -c restricted=true \
      || return
    ok "created inner Incus project '$PROJECT'"
  fi
  inner_incus project set "$PROJECT" limits.instances 2 || return
  inner_incus project set "$PROJECT" limits.virtual-machines 2 || return
  inner_incus project set "$PROJECT" limits.cpu "$total_cpu" || return
  inner_incus project set "$PROJECT" limits.memory "$total_memory" || return
  inner_incus project set "$PROJECT" restricted true || return
  inner_incus project set "$PROJECT" user.subyard.managed "$MARKER" || return

  if ! inner_incus profile device list default --project "$PROJECT" 2>/dev/null | grep -qx root; then
    inner_incus profile device add default root disk pool=default path=/ \
      --project "$PROJECT" >/dev/null || return
  fi
  inner_incus profile device set default root size "$DISK" --project "$PROJECT" || return
  if ! inner_incus profile device list default --project "$PROJECT" 2>/dev/null | grep -qx eth0; then
    inner_incus profile device add default eth0 nic network=incusbr0 name=eth0 \
      --project "$PROJECT" >/dev/null || return
  fi
}

cloud_config() {
  local public_key
  public_key="$(cat "$KEY.pub")"
  cat <<EOF
#cloud-config
users:
  - default
  - name: dev
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    # OpenSSH rejects public keys for a shadow-locked user on Debian 13. "x" is deliberately not
    # a valid password hash: it unlocks public-key login without creating a usable password.
    lock_passwd: false
    passwd: x
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
package_update: true
packages: [openssh-server, sudo]
runcmd:
  - [systemctl, enable, --now, ssh]
EOF
}

ensure_vm() {
  local vm="$1" type raw_apparmor
  if vm_exists "$vm"; then
    type="$(inner_incus list "$vm" --project "$PROJECT" -f csv -c t)" || return
    [ "$type" = VIRTUAL-MACHINE ] || die "managed name '$vm' is not a virtual machine"
    [ "$(vm_marker "$vm")" = "$MARKER" ] || die "VM '$vm' exists without the Subyard marker"
  else
    run_with_progress "creating $vm from $IMAGE (first use downloads the image)" \
      inner_incus init "$IMAGE" "$vm" --vm --project "$PROJECT" \
      -c limits.cpu="$CPU" -c limits.memory="$MEMORY" -c user.subyard.managed="$MARKER" \
      || return
    inner_incus config set "$vm" cloud-init.user-data "$(cloud_config)" \
      --project "$PROJECT" || return
    ok "created $vm"
  fi
  inner_incus config set "$vm" limits.cpu "$CPU" --project "$PROJECT" || return
  inner_incus config set "$vm" limits.memory "$MEMORY" --project "$PROJECT" || return
  # Remove the superseded per-instance workaround before tightening an upgraded project. AppArmor
  # compatibility is now handled once by the trusted inner daemon, outside this restricted project.
  raw_apparmor="$(inner_incus config get "$vm" raw.apparmor --project "$PROJECT")" || return
  [ -z "$raw_apparmor" ] \
    || inner_incus config unset "$vm" raw.apparmor --project "$PROJECT" || return
}

tighten_project() {
  # Older workers enabled this solely for raw.apparmor. Emptying it is idempotent in Incus 6.0 and
  # ensures the fixed test project no longer accepts arbitrary low-level VM configuration.
  inner_incus project unset "$PROJECT" restricted.virtual-machines.lowlevel || return
}

start_vm() {
  local vm="$1" state
  state="$(inner_incus list "$vm" --project "$PROJECT" -f csv -c s)" || return
  if [ "$state" != RUNNING ]; then
    run_with_progress "starting $vm" inner_incus start "$vm" --project "$PROJECT" || return
    ok "started $vm"
  fi
}

wait_agent() {
  local vm="$1" account_status deadline=$((SECONDS + BOOT_TIMEOUT)) started=$SECONDS next_report=$((SECONDS + 10))
  info "waiting for $vm Incus agent"
  until inner_incus exec "$vm" --project "$PROJECT" -- true >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm did not expose the Incus agent within ${BOOT_TIMEOUT}s"
    if [ "$SECONDS" -ge "$next_report" ]; then
      info "waiting for $vm Incus agent ($((SECONDS - started))s elapsed)"
      next_report=$((SECONDS + 10))
    fi
    sleep 2
  done
  ok "$vm Incus agent is ready"
  run_with_progress "waiting for $vm cloud-init" \
    inner_incus exec "$vm" --project "$PROJECT" -- timeout "$BOOT_TIMEOUT" cloud-init status --wait \
    >/dev/null || return
  # Reconcile images created by older workers too. A locked shadow entry makes modern OpenSSH reject
  # even a matching authorized key; the invalid marker unlocks key login but can never authenticate
  # as a password. ssh_pwauth remains disabled and is verified before the VM is declared ready.
  inner_incus exec "$vm" --project "$PROJECT" -- usermod --password x dev || return
  account_status="$(inner_incus exec "$vm" --project "$PROJECT" -- passwd --status dev)" || return
  case "$account_status" in 'dev P '*) ;; *) die "$vm dev account did not become key-login capable" ;; esac
  inner_incus exec "$vm" --project "$PROJECT" -- sshd -T \
    | grep -Fxq 'passwordauthentication no' \
    || die "$vm SSH password authentication is not disabled"
  inner_incus exec "$vm" --project "$PROJECT" -- systemctl is-active --quiet ssh || return
  ok "$vm cloud-init and SSH service are ready"
}

vm_ip() {
  local vm="$1"
  inner_incus list "$vm" --project "$PROJECT" --format json \
    | jq -er '
        [.[0].state.network
          | to_entries[]
          | select(.key != "lo")
          | .value.addresses[]?
          | select(.family == "inet" and .scope == "global")
          | .address]
        | unique
        | if length == 1 then .[0]
          else error("expected exactly one non-loopback global IPv4 address")
          end'
}

ssh_options() {
  printf '%s\n' -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=8
}

record_host_key() {
  local vm="$1" ip keyscan deadline=$((SECONDS + BOOT_TIMEOUT)) started=$SECONDS next_report=$((SECONDS + 10))
  ip="$(vm_ip "$vm")" || die "$vm has no IPv4 address on eth0"
  info "waiting for $vm SSH host key ($ip)"
  until keyscan="$(ssh-keyscan -T 3 "$ip" 2>/dev/null)" && [ -n "$keyscan" ]; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm SSH host key was not reachable within ${BOOT_TIMEOUT}s"
    if [ "$SECONDS" -ge "$next_report" ]; then
      info "waiting for $vm SSH host key ($((SECONDS - started))s elapsed)"
      next_report=$((SECONDS + 10))
    fi
    sleep 2
  done
  printf '%s\n' "$keyscan" >> "$KNOWN_HOSTS"
  ok "$vm SSH host key recorded"
}

ssh_smoke() {
  local vm="$1" ip deadline=$((SECONDS + BOOT_TIMEOUT)) started=$SECONDS next_report=$((SECONDS + 10)); shift
  local -a options=()
  mapfile -t options < <(ssh_options)
  ip="$(vm_ip "$vm")" || return
  info "verifying $vm SSH and passwordless sudo"
  until ssh "${options[@]}" "dev@$ip" -- sudo -n true >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm SSH/sudo smoke did not pass within ${BOOT_TIMEOUT}s"
    if [ "$SECONDS" -ge "$next_report" ]; then
      info "verifying $vm SSH and passwordless sudo ($((SECONDS - started))s elapsed)"
      next_report=$((SECONDS + 10))
    fi
    sleep 2
  done
  ok "$vm SSH and passwordless sudo verified"
}

cleanup_managed() {
  local quiet="${1:-0}" vm name names extra=0
  if project_exists; then
    [ "$(project_marker)" = "$MARKER" ] \
      || die "project '$PROJECT' is not Subyard-managed; refusing cleanup"
    names="$(inner_incus list --project "$PROJECT" -f csv -c n)" \
      || { printf 'test-vms: could not inventory managed project before cleanup\n' >&2; return 1; }
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in "$PREFIX-1" | "$PREFIX-2") ;; *) extra=1; printf 'test-vms: unexpected instance blocks cleanup: %s\n' "$name" >&2 ;; esac
    done <<<"$names"
    [ "$extra" = 0 ] || die "refusing to force-delete a project with unexpected instances"
    for vm in "$PREFIX-1" "$PREFIX-2"; do
      vm_exists "$vm" || continue
      [ "$(vm_marker "$vm")" = "$MARKER" ] || die "VM '$vm' is not Subyard-managed"
      inner_incus delete "$vm" --project "$PROJECT" --force || return
    done
    # The two owned instances were removed explicitly above. A normal delete is now non-interactive
    # and fails closed if any other project resource exists; Incus 6.0's --force always prompts.
    inner_incus project delete "$PROJECT" || return
  fi
  rm -f "$KEY" "$KEY.pub" "$KNOWN_HOSTS" "$CREATED_AT" "$FAILURE_LOG"
  [ "$quiet" = 1 ] || ok "deleted both disposable VMs, inner project and synthetic SSH identity"
}

collect_failure_diagnostics() {
  local rc="$1" vm profile created temp="${FAILURE_LOG}.tmp.$$"
  ensure_state_dir || return 1
  if ! {
    printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'worker_exit=%s\n' "$rc"
    printf 'project=%s\n' "$PROJECT"
    printf '\n== inner Incus AppArmor mode ==\n'
    if systemctl show incus.service --property=Environment --value 2>/dev/null \
      | tr ' ' '\n' | grep -Fxq 'INCUS_SECURITY_APPARMOR=false'; then
      printf 'per_instance_profiles=disabled\n'
    else
      printf 'per_instance_profiles=unexpectedly_enabled_or_unknown\n'
    fi
    if project_exists; then
      printf '\n== project ==\n'
      inner_incus project show "$PROJECT" || true
      for vm in "$PREFIX-1" "$PREFIX-2"; do
        vm_exists "$vm" || continue
        printf '\n== %s info/log ==\n' "$vm"
        inner_incus info --show-log "$vm" --project "$PROJECT" || true
        profile="/var/lib/incus/security/apparmor/profiles/incus-${PROJECT}_${vm}"
        if command -v sudo >/dev/null 2>&1 && sudo -n test -r "$profile" 2>/dev/null; then
          printf '\n== %s residual AppArmor profile file ==\n' "$vm"
          sudo -n awk '/^profile |unix .*type=|### Configuration: raw.apparmor/{print}' "$profile" || true
        fi
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
          created="$(cat "$CREATED_AT" 2>/dev/null || true)"
          if [[ "$created" =~ ^[0-9]+$ ]]; then
            printf '\n== %s bounded kernel denials since this allocation ==\n' "$vm"
            sudo -n dmesg --since "@$created" 2>/dev/null \
              | grep -F "profile=\"incus-${PROJECT}_${vm}_</var/lib/incus>\"" \
              | tail -n 40 || true
          fi
        fi
      done
    else
      printf 'project_state=absent\n'
    fi
  } >"$temp" 2>&1; then
    rm -f "$temp"
    return 1
  fi
  chmod 0640 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$FAILURE_LOG" || { rm -f "$temp"; return 1; }
  printf 'test-vms: failure diagnostics saved to %s\n' "$FAILURE_LOG" >&2
  sed -n '1,240p' "$FAILURE_LOG" >&2
}

cmd_up() {
  local vm
  printf 'Create/start exactly two disposable nested VMs with SSH and passwordless sudo.\n'
  printf 'They expire automatically after %s minutes.\n' "$TTL_MINUTES"
  confirm
  ensure_key || return
  rm -f "$FAILURE_LOG"
  UP_FAILED=1
  trap up_failure_on_exit EXIT
  ensure_project || return
  printf '%s\n' "$(date +%s)" > "$CREATED_AT"
  : > "$KNOWN_HOSTS"
  for vm in "$PREFIX-1" "$PREFIX-2"; do ensure_vm "$vm" || return; done
  tighten_project || return
  for vm in "$PREFIX-1" "$PREFIX-2"; do start_vm "$vm" || return; done
  for vm in "$PREFIX-1" "$PREFIX-2"; do
    wait_agent "$vm" || return
    record_host_key "$vm" || return
  done
  chmod 0644 "$KNOWN_HOSTS"
  for vm in "$PREFIX-1" "$PREFIX-2"; do ssh_smoke "$vm" || return; done
  UP_FAILED=0
  trap - EXIT
  ok "both VMs are ready: use 'yard test-vms ssh 1' or 'yard test-vms exec 2 -- <command>'"
}

up_failure_on_exit() {
  local rc=$?
  trap - EXIT
  if [ "${UP_FAILED:-1}" = 1 ]; then
    collect_failure_diagnostics "$rc" || true
    printf 'test-vms: failed allocation was left in place for diagnosis; operator cleanup: yard test-vms down\n' >&2
  fi
  exit "$rc"
}

cmd_status() {
  local vm state ip created expires now remaining
  if ! project_exists; then printf 'test-vms: down\n'; return; fi
  [ "$(project_marker)" = "$MARKER" ] || die "project '$PROJECT' is not Subyard-managed"
  expires=0
  if [ -r "$CREATED_AT" ]; then
    created="$(cat "$CREATED_AT")"
    [[ "$created" =~ ^[0-9]+$ ]] && expires=$((created + TTL_MINUTES * 60))
  fi
  now="$(date +%s)"; remaining=$((expires - now)); [ "$remaining" -gt 0 ] || remaining=0
  for vm in "$PREFIX-1" "$PREFIX-2"; do
    if vm_exists "$vm"; then
      [ "$(vm_marker "$vm")" = "$MARKER" ] || die "VM '$vm' is not Subyard-managed"
      state="$(inner_incus list "$vm" --project "$PROJECT" -f csv -c s)"
      ip="$(vm_ip "$vm" 2>/dev/null || true)"
      printf '%s\t%s\t%s\n' "$vm" "$state" "${ip:--}"
    else
      printf '%s\tMISSING\t-\n' "$vm"
    fi
  done
  printf 'ttl_remaining_seconds\t%s\n' "$remaining"
}

cmd_down() {
  printf 'Delete both disposable VMs, their inner Incus project and synthetic SSH identity.\n'
  confirm
  cleanup_managed 0
}

cmd_gc() {
  local created now
  project_exists || return 0
  [ "$(project_marker)" = "$MARKER" ] || return 0
  [ -r "$CREATED_AT" ] || return 0
  created="$(cat "$CREATED_AT")"; [[ "$created" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  [ $((now - created)) -lt $((TTL_MINUTES * 60)) ] || cleanup_managed 1
}

cmd_ssh() {
  local vm ip; vm="$(vm_name "${1:-}")"
  require_managed_vm "$vm"
  local -a options=(); mapfile -t options < <(ssh_options)
  ip="$(vm_ip "$vm")"
  exec ssh -tt "${options[@]}" "dev@$ip"
}

cmd_exec() {
  local vm ip; vm="$(vm_name "${1:-}")"; shift || true
  [ "${1:-}" != -- ] || shift
  [ "$#" -gt 0 ] || die "exec requires a command after the VM selector"
  require_managed_vm "$vm"
  local -a options=(); mapfile -t options < <(ssh_options)
  ip="$(vm_ip "$vm")"
  exec ssh -T "${options[@]}" "dev@$ip" -- "$@"
}

main() {
  local -a args=(); local arg
  for arg in "$@"; do
    case "$arg" in --yes | -y) ASSUME_YES=1 ;; --help | -h) usage; return ;; *) args+=("$arg") ;; esac
  done
  set -- "${args[@]}"
  validate_config
  command -v "$INCUS" >/dev/null 2>&1 || die "inner Incus is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  case "${1:-}" in
    up) shift; [ "$#" -eq 0 ] || die "up takes no positional arguments"; cmd_up ;;
    status) shift; [ "$#" -eq 0 ] || die "status takes no positional arguments"; cmd_status ;;
    ssh) shift; cmd_ssh "$@" ;;
    exec) shift; cmd_exec "$@" ;;
    down) shift; [ "$#" -eq 0 ] || die "down takes no positional arguments"; cmd_down ;;
    gc) shift; [ "$#" -eq 0 ] || die "gc takes no positional arguments"; cmd_gc ;;
    '' | help) usage ;;
    *) die "unknown command '$1' (expected up, status, ssh, exec or down)" ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
