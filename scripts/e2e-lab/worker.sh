#!/usr/bin/env bash
# Trusted L1 worker for two disposable nested Incus VMs.
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
DISK="${E2E_VM_DISK:-10GiB}"
TTL_MINUTES="${E2E_VM_TTL_MINUTES:-240}"
BOOT_TIMEOUT="${E2E_VM_BOOT_TIMEOUT:-300}"
DEV_USER="${DEV_USER:-dev}"
STATE_DIR="${E2E_VM_STATE_DIR:-/var/lib/subyard/test-vms}"
PUBLIC_DIR="${E2E_VM_PUBLIC_DIR:-/var/lib/subyard/test-vms-public}"
MANIFEST="$PUBLIC_DIR/allocation.tsv"
AGENT_USER="${E2E_AGENT_USER:-subyard-e2e-agent}"
AGENT_PUBLIC_KEY="${E2E_AGENT_PUBLIC_KEY:-}"
AGENT_HOME="${E2E_AGENT_HOME:-/var/lib/subyard/e2e-agent}"
AGENT_AUTHORIZED_KEYS="${E2E_AGENT_AUTHORIZED_KEYS:-$AGENT_HOME/.ssh/authorized_keys}"
AGENT_KEY_MARKER="subyard-managed-e2e-agent"
STATUS_COMMAND="${E2E_AGENT_STATUS_COMMAND:-/usr/local/libexec/subyard/test-vms-status}"
MARKER="test-vms-v1"
INCUS="${SUBYARD_INNER_INCUS:-incus}"

KEY="$STATE_DIR/id_ed25519"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
CREATED_AT="$STATE_DIR/created-at"
FAILURE_LOG="$STATE_DIR/last-failure.log"
WORKER_KEY_REVISION="$STATE_DIR/worker-key-v2"
REVOKED_WORKER_KEY="$STATE_DIR/revoked-worker.pub"
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
  down                delete both VMs, their project and operator worker SSH key

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
  [ "$disk_mib" -ge 10240 ] || die "E2E_VM_DISK must be at least 10GiB"
  case "$IMAGE" in '' | -* | *[!A-Za-z0-9._:/@+-]*) die "unsafe E2E_VM_IMAGE '$IMAGE'" ;; esac
  [[ "$TTL_MINUTES" =~ ^[0-9]+$ ]] && [ "$TTL_MINUTES" -ge 15 ] && [ "$TTL_MINUTES" -le 1440 ] \
    || die "E2E_VM_TTL_MINUTES must be from 15 to 1440"
  [[ "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$BOOT_TIMEOUT" -ge 30 ] && [ "$BOOT_TIMEOUT" -le 1800 ] \
    || die "E2E_VM_BOOT_TIMEOUT must be from 30 to 1800"
  case "$AGENT_USER" in '' | -* | *[!a-z0-9_-]*) die "unsafe E2E_AGENT_USER '$AGENT_USER'" ;; esac
  case "$AGENT_HOME" in /var/lib/subyard/*) ;; *) die "unsafe E2E_AGENT_HOME '$AGENT_HOME'" ;; esac
  case "$PUBLIC_DIR" in /var/lib/subyard/* | /tmp/*) ;; *) die "unsafe E2E_VM_PUBLIC_DIR '$PUBLIC_DIR'" ;; esac
  case "$STATUS_COMMAND" in /usr/local/libexec/subyard/*) ;; *) die "unsafe E2E_AGENT_STATUS_COMMAND '$STATUS_COMMAND'" ;; esac
  if [ -n "$AGENT_PUBLIC_KEY" ]; then
    [[ "$AGENT_PUBLIC_KEY" != *$'\n'* && "$AGENT_PUBLIC_KEY" != *$'\r'* ]] \
      || die "E2E_AGENT_PUBLIC_KEY must be one line"
    [[ "$AGENT_PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
      || die "E2E_AGENT_PUBLIC_KEY must be an Ed25519 public key"
  fi
}

normalized_agent_public_key() {
  local type blob _rest
  [ -n "$AGENT_PUBLIC_KEY" ] || return 1
  read -r type blob _rest <<<"$AGENT_PUBLIC_KEY"
  printf '%s %s\n' "$type" "$blob"
}

project_exists() { inner_incus project show "$PROJECT" >/dev/null 2>&1; }
project_marker() { inner_incus project get "$PROJECT" user.subyard.managed 2>/dev/null || true; }
vm_exists() { inner_incus info "$1" --project "$PROJECT" >/dev/null 2>&1; }
vm_marker() { inner_incus config get "$1" user.subyard.managed --project "$PROJECT" 2>/dev/null || true; }

ensure_state_dir() {
  if [ "$(id -u)" = 0 ]; then
    install -d -m 0700 -o root -g root "$STATE_DIR"
  else
    [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ] \
      || die "state directory is not writable; re-run yard init on the owner host"
  fi
}

ensure_key() {
  ensure_state_dir
  if [ ! -e "$WORKER_KEY_REVISION" ]; then
    if [ -s "$KEY.pub" ]; then
      awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' "$KEY.pub" \
        > "$REVOKED_WORKER_KEY"
      chmod 0600 "$REVOKED_WORKER_KEY"
    fi
    rm -f "$KEY" "$KEY.pub"
  fi
  if [ ! -s "$KEY" ] || [ ! -s "$KEY.pub" ]; then
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C subyard-managed-e2e-worker -f "$KEY"
  fi
  : > "$WORKER_KEY_REVISION"
  [ "$(id -u)" != 0 ] || chown root:root "$KEY" "$KEY.pub"
  chmod 0600 "$KEY" "$WORKER_KEY_REVISION"
  chmod 0644 "$KEY.pub"
}

memory_to_mib() {
  local value="$1"
  case "$value" in
    *GiB) printf '%s\n' "$(( ${value%GiB} * 1024 ))" ;;
    *MiB) printf '%s\n' "${value%MiB}" ;;
    *) return 1 ;;
  esac
}

ensure_project() {
  local total_cpu memory_number memory_unit total_memory total_memory_mib name names
  local current_cpu current_memory current_memory_mib
  total_cpu=$((CPU * 2))
  memory_unit="${MEMORY##*[0-9]}"; memory_number="${MEMORY%$memory_unit}"
  total_memory="$((memory_number * 2))$memory_unit"
  total_memory_mib="$(memory_to_mib "$total_memory")" || return
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
    # Raise aggregate limits before growing VM limits.
    current_cpu="$(inner_incus project get "$PROJECT" limits.cpu)" || return
    if [[ "$current_cpu" =~ ^[0-9]+$ ]] && [ "$current_cpu" -lt "$total_cpu" ]; then
      inner_incus project set "$PROJECT" limits.cpu "$total_cpu" || return
    fi
    current_memory="$(inner_incus project get "$PROJECT" limits.memory)" || return
    if [ -n "$current_memory" ]; then
      current_memory_mib="$(memory_to_mib "$current_memory")" \
        || die "managed project has an unsupported memory limit: $current_memory"
      if [ "$current_memory_mib" -lt "$total_memory_mib" ]; then
        inner_incus project set "$PROJECT" limits.memory "$total_memory" || return
      fi
    fi
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
  local public_key agent_key=''
  public_key="$(cat "$KEY.pub")"
  agent_key="$(normalized_agent_public_key 2>/dev/null || true)"
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
EOF
  [ -z "$agent_key" ] || printf '      - %s %s\n' "$agent_key" "$AGENT_KEY_MARKER"
  cat <<'EOF'
ssh_pwauth: false
package_update: true
packages: [openssh-server, sudo, git, curl, jq, ripgrep, golang-go, shellcheck]
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
  local total_cpu memory_number memory_unit total_memory
  total_cpu=$((CPU * 2))
  memory_unit="${MEMORY##*[0-9]}"; memory_number="${MEMORY%$memory_unit}"
  total_memory="$((memory_number * 2))$memory_unit"
  # VM limits now permit shrinking aggregate limits.
  inner_incus project set "$PROJECT" limits.cpu "$total_cpu" || return
  inner_incus project set "$PROJECT" limits.memory "$total_memory" || return
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
  local vm="$1" account_status sshd_config deadline=$((SECONDS + BOOT_TIMEOUT)) started=$SECONDS next_report=$((SECONDS + 10))
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
    wait_cloud_init "$vm" || return
  # Reconcile images created by older workers too. A locked shadow entry makes modern OpenSSH reject
  # even a matching authorized key; the invalid marker unlocks key login but can never authenticate
  # as a password. ssh_pwauth remains disabled and is verified before the VM is declared ready.
  inner_incus exec "$vm" --project "$PROJECT" -- usermod --password x dev || return
  account_status="$(inner_incus exec "$vm" --project "$PROJECT" -- passwd --status dev)" || return
  case "$account_status" in 'dev P '*) ;; *) die "$vm dev account did not become key-login capable" ;; esac
  # Debian sshd uses the first included value; install this policy first.
  inner_incus exec "$vm" --project "$PROJECT" -- sh -eu -c '
    directory=/etc/ssh/sshd_config.d
    target="$directory/00-subyard-e2e.conf"
    install -d -m 0755 "$directory"
    temp="$(mktemp "$directory/.subyard-e2e.XXXXXX")"
    trap '\''rm -f "$temp"'\'' EXIT
    printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\n" > "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$target"
    trap - EXIT
    sshd -t
    systemctl reload ssh
  ' || return
  # Capture output before matching to avoid a pipefail broken pipe.
  sshd_config="$(inner_incus exec "$vm" --project "$PROJECT" -- sshd -T)" || return
  printf '%s\n' "$sshd_config" | grep -Fx 'passwordauthentication no' >/dev/null \
    || die "$vm SSH password authentication is not disabled"
  inner_incus exec "$vm" --project "$PROJECT" -- systemctl is-active --quiet ssh || return
  ok "$vm cloud-init and SSH service are ready"
}

wait_cloud_init() {
  local vm="$1"
  inner_incus exec "$vm" --project "$PROJECT" -- \
    timeout "$BOOT_TIMEOUT" cloud-init status --wait >/dev/null
}

ensure_guest_tools() {
  local vm="$1"
  if inner_incus exec "$vm" --project "$PROJECT" -- sh -c \
    'command -v git >/dev/null && command -v curl >/dev/null && command -v jq >/dev/null && command -v rg >/dev/null && command -v go >/dev/null && command -v shellcheck >/dev/null'; then
    return 0
  fi
  run_with_progress "installing test toolchain in $vm" \
    inner_incus exec "$vm" --project "$PROJECT" -- sh -eu -c \
      'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq git curl jq ripgrep golang-go shellcheck' \
    || return
  ok "$vm test toolchain is ready"
}

install_managed_guest_keys() {
  local vm="$1" worker_key agent_key='' revoked_key=''
  worker_key="$(awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' "$KEY.pub")"
  agent_key="$(normalized_agent_public_key 2>/dev/null || true)"
  [ ! -s "$REVOKED_WORKER_KEY" ] \
    || revoked_key="$(awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' "$REVOKED_WORKER_KEY")"
  validate_public_key "$vm worker identity" "$worker_key"
  [ -z "$agent_key" ] || validate_public_key "$vm agent identity" "$agent_key"
  inner_incus exec "$vm" --project "$PROJECT" \
    --env WORKER_KEY="$worker_key" \
    --env AGENT_KEY="$agent_key" \
    --env REVOKED_WORKER_KEY="$revoked_key" \
    --env AGENT_KEY_MARKER="$AGENT_KEY_MARKER" \
    -- sh -eu -c '
      home=/home/dev
      ssh_dir="$home/.ssh"
      authorized="$ssh_dir/authorized_keys"
      install -d -m 0700 -o dev -g dev "$ssh_dir"
      touch "$authorized"
      temp="$(mktemp "$ssh_dir/.authorized-keys.XXXXXX")"
      revoked_type="${REVOKED_WORKER_KEY%% *}"
      revoked_blob="${REVOKED_WORKER_KEY#* }"
      awk -v agent_marker="$AGENT_KEY_MARKER" \
          -v revoked_type="$revoked_type" -v revoked_blob="$revoked_blob" '\''
        $NF == "subyard-test-vms" || $NF == "subyard-managed-e2e-worker" || $NF == agent_marker { next }
        {
          drop = 0
          if (revoked_type != "" && revoked_blob != "") {
            for (i = 1; i < NF; i++) {
              if ($i == revoked_type && $(i + 1) == revoked_blob) drop = 1
            }
          }
          if (!drop) print
        }
      '\'' "$authorized" > "$temp"
      printf "%s subyard-managed-e2e-worker\n" "$WORKER_KEY" >> "$temp"
      [ -z "$AGENT_KEY" ] || printf "%s %s\n" "$AGENT_KEY" "$AGENT_KEY_MARKER" >> "$temp"
      chmod 0600 "$temp"
      chown dev:dev "$temp"
      mv -f "$temp" "$authorized"
    '
}

vm_ip() {
  local vm="$1" routes interface
  routes="$(inner_incus exec "$vm" --project "$PROJECT" -- ip -4 route show default)" || return
  interface="$({
    printf '%s\n' "$routes" \
      | awk '$1 == "default" { for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }' \
      | sort -u
  })"
  [[ "$interface" =~ ^[[:alnum:]_.:-]+$ ]] \
    || { printf 'test-vms: expected exactly one default-route interface for %s\n' "$vm" >&2; return 1; }
  inner_incus list "$vm" --project "$PROJECT" --format json \
    | jq -er --arg interface "$interface" '
        [.[0].state.network[$interface].addresses[]?
          | select(.family == "inet" and .scope == "global")
          | .address]
        | unique
        | if length == 1 then .[0]
          else error("expected exactly one global IPv4 address on the default-route interface")
          end'
}

ssh_options() {
  printf '%s\n' -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=8
}

record_host_key() {
  local vm="$1" ip keyscan deadline=$((SECONDS + BOOT_TIMEOUT)) started=$SECONDS next_report=$((SECONDS + 10))
  ip="$(vm_ip "$vm")" || die "$vm has no IPv4 address on its default-route interface"
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

ensure_guest_peer_key() {
  local vm="$1"
  inner_incus exec "$vm" --project "$PROJECT" -- sh -eu -c '
    install -d -m 0700 -o dev -g dev /home/dev/.ssh
    if [ ! -s /home/dev/.ssh/id_ed25519 ] || [ ! -s /home/dev/.ssh/id_ed25519.pub ]; then
      rm -f /home/dev/.ssh/id_ed25519 /home/dev/.ssh/id_ed25519.pub
      runuser -u dev -- ssh-keygen -q -t ed25519 -N "" -C subyard-e2e-peer \
        -f /home/dev/.ssh/id_ed25519
    fi
    awk '\''$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }'\'' \
      /home/dev/.ssh/id_ed25519.pub
  '
}

guest_host_public_key() {
  local vm="$1"
  inner_incus exec "$vm" --project "$PROJECT" -- \
    awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' \
      /etc/ssh/ssh_host_ed25519_key.pub
}

kill_agent_sessions() {
  id -u "$AGENT_USER" >/dev/null 2>&1 || return 0
  command -v pkill >/dev/null 2>&1 || return 0
  pkill -KILL -u "$AGENT_USER" >/dev/null 2>&1 || true
}

write_agent_authorized_keys() {
  local ip1="${1:-}" ip2="${2:-}" key options temp directory primary
  [ -n "$AGENT_PUBLIC_KEY" ] || return 0
  id -u "$AGENT_USER" >/dev/null 2>&1 || die "agent bastion account is missing; re-run yard init"
  key="$(normalized_agent_public_key)"
  directory="$(dirname "$AGENT_AUTHORIZED_KEYS")"
  if [ "$(id -u)" = 0 ]; then
    primary="$(id -gn "$AGENT_USER")"
    install -d -m 0750 -o root -g "$primary" "$directory"
  else
    install -d -m 0700 "$directory"
  fi
  options="restrict,command=\"$STATUS_COMMAND\""
  if [ -n "$ip1" ] || [ -n "$ip2" ]; then
    [[ "$ip1" =~ ^[0-9]+(\.[0-9]+){3}$ && "$ip2" =~ ^[0-9]+(\.[0-9]+){3}$ ]] \
      || die "cannot publish non-IPv4 VM targets"
    options="restrict,port-forwarding,permitopen=\"$ip1:22\",permitopen=\"$ip2:22\",command=\"$STATUS_COMMAND\""
  fi
  temp="$(mktemp "$directory/.authorized-keys.XXXXXX")"
  printf '%s %s %s\n' "$options" "$key" "$AGENT_KEY_MARKER" > "$temp"
  if [ "$(id -u)" = 0 ]; then
    chmod 0640 "$temp"
    chown root:"$primary" "$temp"
  else
    chmod 0600 "$temp"
  fi
  mv -f "$temp" "$AGENT_AUTHORIZED_KEYS"
}

write_manifest() {
  local state="$1" reason="$2" ip1="${3:-}" host1="${4:-}" ip2="${5:-}" host2="${6:-}"
  local temp created=0 expires=0 host1_type host1_blob host1_extra host2_type host2_blob host2_extra
  if [ "$(id -u)" = 0 ]; then
    install -d -m 0755 -o root -g root "$PUBLIC_DIR"
  else
    install -d -m 0755 "$PUBLIC_DIR"
  fi
  if [ -r "$CREATED_AT" ]; then
    created="$(cat "$CREATED_AT")"
    [[ "$created" =~ ^[0-9]+$ ]] || created=0
  fi
  [ "$created" = 0 ] || expires=$((created + TTL_MINUTES * 60))
  temp="$(mktemp "$PUBLIC_DIR/.allocation.XXXXXX")"
  {
    printf 'subyard-e2e-allocation-v1\n'
    printf 'state\t%s\n' "$state"
    printf 'reason\t%s\n' "$reason"
    printf 'allocation_id\t%s\n' "$created"
    printf 'expires_at_epoch\t%s\n' "$expires"
    if [ "$state" = ready ]; then
      read -r host1_type host1_blob host1_extra <<<"$host1"
      read -r host2_type host2_blob host2_extra <<<"$host2"
      [ "$host1_type" = ssh-ed25519 ] && [ -n "$host1_blob" ] && [ -z "$host1_extra" ] \
        || die "cannot publish an invalid VM1 host key"
      [ "$host2_type" = ssh-ed25519 ] && [ -n "$host2_blob" ] && [ -z "$host2_extra" ] \
        || die "cannot publish an invalid VM2 host key"
      printf 'vm\t1\t%s-1\t%s\t%s\t%s\n' "$PREFIX" "$ip1" "$host1_type" "$host1_blob"
      printf 'vm\t2\t%s-2\t%s\t%s\t%s\n' "$PREFIX" "$ip2" "$host2_type" "$host2_blob"
    fi
  } > "$temp"
  chmod 0644 "$temp"
  [ "$(id -u)" != 0 ] || chown root:root "$temp"
  mv -f "$temp" "$MANIFEST"
}

restrict_agent_access() {
  local reason="${1:-not-ready}"
  kill_agent_sessions
  write_agent_authorized_keys
  write_manifest down "$reason"
}

enable_agent_access() {
  local vm1="$PREFIX-1" vm2="$PREFIX-2" ip1 ip2 host1 host2
  ip1="$(vm_ip "$vm1")" || return
  ip2="$(vm_ip "$vm2")" || return
  host1="$(guest_host_public_key "$vm1")" || return
  host2="$(guest_host_public_key "$vm2")" || return
  validate_public_key "$vm1 host identity" "$host1"
  validate_public_key "$vm2 host identity" "$host2"
  kill_agent_sessions
  write_agent_authorized_keys "$ip1" "$ip2"
  write_manifest ready ready "$ip1" "$host1" "$ip2" "$host2"
}

reconcile_existing_agent_access() {
  local vm name names state
  restrict_agent_access reconciling
  project_exists || return 0
  [ "$(project_marker)" = "$MARKER" ] \
    || die "project '$PROJECT' exists without the Subyard marker; agent access remains disabled"
  names="$(inner_incus list --project "$PROJECT" -f csv -c n)" || return
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in "$PREFIX-1" | "$PREFIX-2") ;; *) die "unexpected instance blocks agent access: $name" ;; esac
  done <<<"$names"
  for vm in "$PREFIX-1" "$PREFIX-2"; do
    vm_exists "$vm" || { write_manifest down incomplete-allocation; return 0; }
    [ "$(vm_marker "$vm")" = "$MARKER" ] \
      || die "VM '$vm' is not Subyard-managed; agent access remains disabled"
    state="$(inner_incus list "$vm" --project "$PROJECT" -f csv -c s)" || return
    [ "$state" = RUNNING ] || { write_manifest down not-running; return 0; }
  done
  ensure_key || return
  : > "$KNOWN_HOSTS"
  for vm in "$PREFIX-1" "$PREFIX-2"; do
    wait_agent "$vm" || return
    ensure_guest_tools "$vm" || return
    install_managed_guest_keys "$vm" || return
    record_host_key "$vm" || return
  done
  chmod 0600 "$KNOWN_HOSTS"
  for vm in "$PREFIX-1" "$PREFIX-2"; do ssh_smoke "$vm" || return; done
  enable_agent_access || return
  rm -f "$REVOKED_WORKER_KEY"
}

validate_public_key() {
  local label="$1" key="$2"
  [[ "$key" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]] \
    || die "$label did not expose one valid Ed25519 public key"
}

install_guest_peer_trust() {
  local target="$1" peer_ip="$2" peer_public_key="$3" peer_host_key="$4"
  inner_incus exec "$target" --project "$PROJECT" \
    --env PEER_IP="$peer_ip" \
    --env PEER_PUBLIC_KEY="$peer_public_key" \
    --env PEER_HOST_KEY="$peer_host_key" \
    -- sh -eu -c '
      home=/home/dev
      ssh_dir="$home/.ssh"
      authorized="$ssh_dir/authorized_keys"
      known="$ssh_dir/known_hosts"
      temp="$(mktemp "$ssh_dir/.known-hosts.XXXXXX")"
      install -d -m 0700 -o dev -g dev "$ssh_dir"
      touch "$authorized" "$known"
      grep -qxF "$PEER_PUBLIC_KEY" "$authorized" \
        || printf "%s\n" "$PEER_PUBLIC_KEY" >> "$authorized"
      awk -v ip="$PEER_IP" '\''$1 != ip { print }'\'' "$known" > "$temp"
      printf "%s %s\n" "$PEER_IP" "$PEER_HOST_KEY" >> "$temp"
      chmod 0600 "$authorized" "$temp"
      chown dev:dev "$authorized" "$temp"
      mv -f "$temp" "$known"
    '
}

peer_ssh_smoke() {
  local source="$1" peer_ip="$2"
  inner_incus exec "$source" --project "$PROJECT" -- runuser -u dev -- \
    ssh -n -i /home/dev/.ssh/id_ed25519 \
      -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=/home/dev/.ssh/known_hosts -o ConnectTimeout=8 \
      "dev@$peer_ip" -- sudo -n true
}

ensure_peer_trust() {
  local vm1="$PREFIX-1" vm2="$PREFIX-2" ip1 ip2 key1 key2 host1 host2
  ip1="$(vm_ip "$vm1")" || return
  ip2="$(vm_ip "$vm2")" || return
  key1="$(ensure_guest_peer_key "$vm1")" || return
  key2="$(ensure_guest_peer_key "$vm2")" || return
  host1="$(guest_host_public_key "$vm1")" || return
  host2="$(guest_host_public_key "$vm2")" || return
  validate_public_key "$vm1 peer identity" "$key1"
  validate_public_key "$vm2 peer identity" "$key2"
  validate_public_key "$vm1 host identity" "$host1"
  validate_public_key "$vm2 host identity" "$host2"
  install_guest_peer_trust "$vm1" "$ip2" "$key2" "$host2" || return
  install_guest_peer_trust "$vm2" "$ip1" "$key1" "$host1" || return
  info "verifying mutual VM SSH trust"
  peer_ssh_smoke "$vm1" "$ip2" || return
  peer_ssh_smoke "$vm2" "$ip1" || return
  ok "both VMs trust each other's synthetic identity and pinned host key"
}

cleanup_managed() {
  local quiet="${1:-0}" vm name names extra=0
  restrict_agent_access down
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
  rm -f "$KEY" "$KEY.pub" "$KNOWN_HOSTS" "$CREATED_AT" "$FAILURE_LOG" \
    "$WORKER_KEY_REVISION" "$REVOKED_WORKER_KEY"
  [ "$quiet" = 1 ] || ok "deleted both disposable VMs, inner project and operator worker identity"
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
  restrict_agent_access provisioning
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
    ensure_guest_tools "$vm" || return
    install_managed_guest_keys "$vm" || return
    record_host_key "$vm" || return
  done
  chmod 0600 "$KNOWN_HOSTS"
  ensure_peer_trust || return
  for vm in "$PREFIX-1" "$PREFIX-2"; do ssh_smoke "$vm" || return; done
  enable_agent_access || return
  rm -f "$REVOKED_WORKER_KEY"
  UP_FAILED=0
  trap - EXIT
  ok "both VMs are ready for the enrolled agent and operator diagnostics"
}

up_failure_on_exit() {
  local rc=$?
  trap - EXIT
  if [ "${UP_FAILED:-1}" = 1 ]; then
    restrict_agent_access allocation-failed || true
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

cmd_reconcile_access() {
  reconcile_existing_agent_access
}

main() {
  local -a args=(); local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --yes | -y) ASSUME_YES=1 ;;
      --help | -h) usage; return ;;
      --) args+=(-- "$@"); break ;;
      *) args+=("$arg") ;;
    esac
  done
  set -- "${args[@]}"
  validate_config
  command -v "$INCUS" >/dev/null 2>&1 || die "inner Incus is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  case "${1:-}" in
    up) shift; [ "$#" -eq 0 ] || die "up takes no positional arguments"; cmd_up ;;
    status) shift; [ "$#" -eq 0 ] || die "status takes no positional arguments"; cmd_status ;;
    down) shift; [ "$#" -eq 0 ] || die "down takes no positional arguments"; cmd_down ;;
    gc) shift; [ "$#" -eq 0 ] || die "gc takes no positional arguments"; cmd_gc ;;
    reconcile-access) shift; [ "$#" -eq 0 ] || die "reconcile-access takes no positional arguments"; cmd_reconcile_access ;;
    '' | help) usage ;;
    *) die "unknown command '$1' (expected up, status or down)" ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
