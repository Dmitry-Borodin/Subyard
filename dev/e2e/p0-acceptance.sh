#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG=''
TOKEN=''
P0_BUNDLE=''
P0_BUNDLE_HASH=''
PEERS_READY=0
PROBE_PID=''
PROBE_MARKER=''
PROBE_NAME=''
PROBE_LOG=''
VM1_YARD_ENTRY=''
VM2_YARD_ENTRY=''
VM1_SSH_STATE=''
VM2_SSH_STATE=''
SOURCE_ARCHIVE=''
SOURCE_ARCHIVE_REMOTE=''
SOURCE_HASH=''
SOURCE_COMMIT=''
SOURCE_HOST_STARTED=0
CANDIDATE_HASH=''
CAPACITY_LOG_DIR=''
PEERS_ONLY="${SUBYARD_P0_PEERS_ONLY:-0}"
declare -A CAPACITY_PID=()
declare -A CAPACITY_FLAG=()
declare -A DEFAULT_BUILD_CACHE_BEFORE=()
declare -A MODULE_CACHE_BEFORE=()
declare -A HOME_STATE_BEFORE=()

# Reuse one ordinary broker lease for the full matrix. This avoids the retired raw SSH-config
# export and ensures every direct and bundled command addresses the same retained pair.
# shellcheck source=dev/agent-e2e.sh
. "$ROOT/dev/agent-e2e.sh"

die() { printf 'p0-acceptance: %s\n' "$*" >&2; exit 2; }
public_tree_hash() {
  local path kind mode digest
  while IFS= read -r -d '' path; do
    if [ -L "$ROOT/$path" ]; then
      kind='link'
      mode=120000
      digest="$(readlink "$ROOT/$path" | sha256sum | awk '{print $1}')"
    elif [ -f "$ROOT/$path" ]; then
      kind='file'
      mode="$(stat -c '%a' "$ROOT/$path")"
      digest="$(sha256sum "$ROOT/$path" | awk '{print $1}')"
    else
      continue
    fi
    printf '%s\0%s\0%s\0%s\0' "$path" "$kind" "$mode" "$digest"
  done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -z | sort -z)
}
p0_guest() {
  local vm="$1"; shift
  guest "$vm" runuser -u dev -- env HOME=/home/dev USER=dev LOGNAME=dev \
    sh -c 'cd "$HOME"; exec "$@"' _ "$@"
}
p0_run_guest() {
  local vm="$1" bundle="$2" bundle_hash="$3"; shift 3
  run_guest "$vm" "$bundle" "$bundle_hash" bash -c '
    parent="$(dirname "$PWD")"
    chown -R dev:dev "$parent"
    exec runuser -u dev -- env HOME=/home/dev USER=dev LOGNAME=dev "$@"
  ' _ "$@"
}
run_vm() {
  local vm="$1" mode="$2" rc=0; shift 2
  p0_run_guest "$vm" "$P0_BUNDLE" "$P0_BUNDLE_HASH" \
    bash dev/e2e/p0-guest.sh "$mode" "$TOKEN" "$@" || rc=$?
  cleanup_guest "$vm" || return 3
  return "$rc"
}
direct_vm() {
  local vm="$1" mode="$2"; shift 2
  p0_guest "$vm" env SUBYARD_E2E_VM="$vm" \
    bash "/tmp/subyard-p0-peer-$TOKEN/src/dev/e2e/p0-guest.sh" "$mode" "$TOKEN" "$@"
}
run_source_vm() {
  local mode="$1" rc=0; shift
  p0_run_guest 1 "$P0_BUNDLE" "$P0_BUNDLE_HASH" \
    bash dev/e2e/p0-source-upgrade.sh "$mode" "$TOKEN" "$@" || rc=$?
  cleanup_guest 1 || return 3
  return "$rc"
}
clean_peers() {
  local rc=0
  run_vm 1 peer-clean || rc=$?
  run_vm 2 peer-clean || rc=$?
  return "$rc"
}
clean_source_host() {
  run_source_vm clean
}
stop_capacity_monitors() {
  local vm pid
  for vm in 1 2; do
    [ -z "${CAPACITY_FLAG[$vm]:-}" ] || find "${CAPACITY_FLAG[$vm]}" -delete 2>/dev/null || true
  done
  for vm in 1 2; do
    pid="${CAPACITY_PID[$vm]:-}"
    [ -z "$pid" ] || wait "$pid" >/dev/null 2>&1 || true
    CAPACITY_PID[$vm]=''
  done
}
cleanup() {
  local rc=$? cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  stop_capacity_monitors
  if [ -n "$PROBE_PID" ]; then
    kill -TERM -- "-$PROBE_PID" >/dev/null 2>&1
    wait "$PROBE_PID" >/dev/null 2>&1
  fi
  if [ -n "$PROBE_NAME" ]; then
    p0_guest 1 pkill -f "^$PROBE_NAME 300$" >/dev/null 2>&1 || true
  fi
  if [ -n "$PROBE_MARKER" ]; then
    p0_guest 1 find "$PROBE_MARKER" -delete >/dev/null 2>&1 || cleanup_failed=1
  fi
  [ "$PEERS_READY" = 0 ] || clean_peers >/dev/null 2>&1 || cleanup_failed=1
  [ "$SOURCE_HOST_STARTED" = 0 ] || clean_source_host >/dev/null 2>&1 || cleanup_failed=1
  if [ -n "$SOURCE_ARCHIVE_REMOTE" ]; then
    p0_guest 1 \
      sh -c '[ ! -e "$1" ] || find "$1" -delete' _ "$SOURCE_ARCHIVE_REMOTE" \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  [ -z "$SOURCE_ARCHIVE" ] || [ ! -e "$SOURCE_ARCHIVE" ] \
    || find "$SOURCE_ARCHIVE" -delete >/dev/null 2>&1 \
    || cleanup_failed=1
  [ -z "$PROBE_LOG" ] || find "$PROBE_LOG" -delete >/dev/null 2>&1 || cleanup_failed=1
  [ -z "$CAPACITY_LOG_DIR" ] || find "$CAPACITY_LOG_DIR" -depth -delete \
    >/dev/null 2>&1 || cleanup_failed=1
  if [ -n "$LEASE_KEEPER_PID" ]; then
    kill "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
    wait "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
    LEASE_KEEPER_PID=''
  fi
  release_lease >/dev/null 2>&1 || cleanup_failed=1
  if [ -n "$LOCAL_TEMP" ]; then
    case "$LOCAL_TEMP" in /tmp/subyard-agent-e2e.*|"${TMPDIR:-/tmp}"/subyard-agent-e2e.*)
      find "$LOCAL_TEMP" -depth -delete >/dev/null 2>&1 || cleanup_failed=1
      ;;
    esac
  fi
  [ "$cleanup_failed" = 0 ] || rc=3
  exit "$rc"
}

capacity_cache_snapshot() {
  local vm="$1"
  p0_guest "$vm" bash -c '
    bytes() {
      if [ -e "$1" ]; then du -sx -B1 "$1" | awk "{print \$1}"; else printf "0\n"; fi
    }
    build="$(env -u GOCACHE go env GOCACHE)"
    modules="$(env -u GOMODCACHE go env GOMODCACHE)"
    printf "%s\t%s\n" "$(bytes "$build")" "$(bytes "$modules")"
  '
}

capacity_monitor() {
  local vm="$1" flag="$2" log="$3"
  while [ -e "$flag" ]; do
    ssh -F "$CONFIG" -T -o ConnectTimeout=3 "e2e-vm-$vm" -- bash -c '
      read -r root_used root_available < <(
        df -B1 --output=used,avail / | awk "NR==2 {print \$1, \$2}"
      )
      inode_used="$(df --output=iused / | awk "NR==2 {print \$1}")"
      tmp_used="$(df -B1 --output=used /tmp | awk "NR==2 {print \$1}")"
      read -r memory_used memory_available < <(
        awk "
          /MemTotal:/ { total=\$2 }
          /MemAvailable:/ { available=\$2 }
          END { print (total-available)*1024, available*1024 }
        " /proc/meminfo
      )
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$(date +%s)" "$root_used" "$root_available" "$inode_used" "$tmp_used" \
        "$memory_used" "$memory_available"
    ' >> "$log" 2>/dev/null || true
    sleep 1
  done
}

start_capacity_monitors() {
  local vm flag log
  CAPACITY_LOG_DIR="$(mktemp -d /tmp/subyard-p0-capacity.XXXXXX)"
  for vm in 1 2; do
    flag="$CAPACITY_LOG_DIR/vm$vm.running"
    log="$CAPACITY_LOG_DIR/vm$vm.tsv"
    : > "$flag"
    : > "$log"
    CAPACITY_FLAG[$vm]="$flag"
    capacity_monitor "$vm" "$flag" "$log" &
    CAPACITY_PID[$vm]=$!
  done
}

capacity_report() {
  local vm log report root_used root_available inode_used tmp_used memory_used memory_available
  local min_root_available="${P0_E2E_MIN_PEAK_ROOT_RESERVE_BYTES:-1073741824}"
  local min_memory_available="${P0_E2E_MIN_PEAK_MEMORY_RESERVE_BYTES:-67108864}"
  stop_capacity_monitors
  for vm in 1 2; do
    log="$CAPACITY_LOG_DIR/vm$vm.tsv"
    report="$(awk -F '\t' '
      NF == 7 {
        if (!seen || $2 > root_used) root_used=$2
        if (!seen || $3 < root_available) root_available=$3
        if (!seen || $4 > inode_used) inode_used=$4
        if (!seen || $5 > tmp_used) tmp_used=$5
        if (!seen || $6 > memory_used) memory_used=$6
        if (!seen || $7 < memory_available) memory_available=$7
        seen=1
      }
      END {
        if (seen) print root_used, root_available, inode_used, tmp_used, memory_used, memory_available
      }
    ' "$log")"
    [ -n "$report" ] || die "VM$vm capacity monitor recorded no samples"
    read -r root_used root_available inode_used tmp_used memory_used memory_available <<<"$report"
    [ "$root_available" -ge "$min_root_available" ] \
      || die "VM$vm peak root reserve fell below $min_root_available bytes: $root_available"
    [ "$memory_available" -ge "$min_memory_available" ] \
      || die "VM$vm peak memory reserve fell below $min_memory_available bytes: $memory_available"
    printf '  [ ok ] VM%s measured peak root_used=%s root_reserve=%s inode_used=%s tmp_used=%s memory_used=%s memory_reserve=%s\n' \
      "$vm" "$root_used" "$root_available" "$inode_used" "$tmp_used" \
      "$memory_used" "$memory_available"
  done
}

verify_cache_lifecycle() {
  local vm after default_after module_after growth max_growth=33554432
  for vm in 1 2; do
    after="$(capacity_cache_snapshot "$vm")"
    IFS=$'\t' read -r default_after module_after <<<"$after"
    growth=$((default_after - DEFAULT_BUILD_CACHE_BEFORE[$vm]))
    [ "$growth" -le "$max_growth" ] \
      || die "VM$vm shared Go build cache grew by $growth bytes; P0 must use its disposable cache"
    printf '  [ ok ] VM%s Go cache lifecycle default_build=%s->%s reusable_modules=%s->%s\n' \
      "$vm" "${DEFAULT_BUILD_CACHE_BEFORE[$vm]}" "$default_after" \
      "${MODULE_CACHE_BEFORE[$vm]}" "$module_after"
  done
}

prepare_source_archive() {
  local revision commit hash remote_hash
  revision="${SUBYARD_P0_SOURCE_REVISION:-7c67ee3}"
  commit="$(git -C "$ROOT" rev-parse --verify "$revision^{commit}")" \
    || die "source revision $revision is unavailable"
  SOURCE_ARCHIVE="$(mktemp /tmp/subyard-p0-source.XXXXXX.tar.gz)"
  git -C "$ROOT" archive --format=tar "$commit" | gzip -n > "$SOURCE_ARCHIVE"
  hash="$(sha256sum "$SOURCE_ARCHIVE" | cut -d' ' -f1)"
  SOURCE_ARCHIVE_REMOTE="/tmp/subyard-p0-source-$TOKEN.tar.gz"
  p0_guest 1 \
    sh -c 'umask 077; dd of="$1" status=none' _ "$SOURCE_ARCHIVE_REMOTE" \
    < "$SOURCE_ARCHIVE"
  remote_hash="$(ssh -F "$CONFIG" -T e2e-vm-1 -- \
    sha256sum "$SOURCE_ARCHIVE_REMOTE" | awk '{print $1}')"
  [ "$remote_hash" = "$hash" ] || die 'source archive changed in transport'
  SOURCE_HASH="$hash"
  SOURCE_COMMIT="$commit"
}

reboot_vm1() {
  local before_boot after_boot='' down=0 host_state up=0 unit_result
  before_boot="$(ssh -F "$CONFIG" -T e2e-vm-1 -- cat /proc/sys/kernel/random/boot_id)" \
    || die 'cannot read VM1 boot ID before reboot'
  set +e
  ssh -F "$CONFIG" -T e2e-vm-1 -- sudo -n systemctl reboot >/dev/null 2>&1
  set -e
  for _ in $(seq 1 60); do
    if ! ssh -F "$CONFIG" -T -o ConnectTimeout=2 e2e-vm-1 -- true \
      >/dev/null 2>&1; then
      down=1
      break
    fi
    sleep 1
  done
  [ "$down" = 1 ] || die 'VM1 did not go down for reboot'
  for _ in $(seq 1 180); do
    after_boot="$(ssh -F "$CONFIG" -T -o ConnectTimeout=3 e2e-vm-1 -- \
      cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || after_boot=''
    if [ -n "$after_boot" ] && [ "$after_boot" != "$before_boot" ]; then
      up=1
      break
    fi
    sleep 1
  done
  [ "$up" = 1 ] || die 'VM1 did not return with a new boot ID'
  set +e
  host_state="$(ssh -F "$CONFIG" -T e2e-vm-1 -- \
    timeout 180 systemctl is-system-running --wait 2>/dev/null)"
  set -e
  case "$host_state" in
    running | degraded) ;;
    *) die "VM1 boot did not reach a terminal systemd state: ${host_state:-unknown}" ;;
  esac
  unit_result="$(ssh -F "$CONFIG" -T e2e-vm-1 -- \
    systemctl show subyard-power-reconcile.service --property=Result --value)"
  [ "$unit_result" = success ] || die "VM1 boot power reconciliation failed: $unit_result"
}
trap cleanup EXIT INT TERM

assert_no_worktrees() {
  local vm leftover
  for vm in 1 2; do
    leftover="$(ssh -F "$CONFIG" -T "e2e-vm-$vm" -- \
      find /tmp -maxdepth 1 -type d -name 'subyard-worktree.*' -print -quit)"
    [ -z "$leftover" ] || die "VM$vm retained an agent worktree"
  done
}

yard_entry_state() {
  local vm="$1"
  p0_guest "$vm" sh -c '
    path="$HOME/.local/bin/yard"
    if [ -L "$path" ]; then
      printf "link\t%s\n" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf "file\t%s\t%s\n" \
        "$(stat -c "%a:%u:%g" "$path")" "$(sha256sum "$path" | cut -d " " -f1)"
    elif [ -e "$path" ]; then
      printf "other\t%s\n" "$(stat -c "%f:%u:%g" "$path")"
    else
      printf "absent\n"
    fi
  '
}

ssh_state() {
  local vm="$1"
  p0_guest "$vm" sh -c '
    for path in "$HOME/.ssh/authorized_keys" "$HOME/.ssh/config"; do
      if [ -L "$path" ]; then
        printf "link\t%s\t%s\n" "$path" "$(readlink "$path")"
      elif [ -f "$path" ]; then
        printf "file\t%s\t%s\t%s\n" "$path" \
          "$(stat -c "%a:%u:%g" "$path")" "$(sha256sum "$path" | cut -d " " -f1)"
      elif [ -e "$path" ]; then
        printf "other\t%s\t%s\n" "$path" "$(stat -c "%f:%u:%g" "$path")"
      else
        printf "absent\t%s\n" "$path"
      fi
    done
  '
}

home_state() {
  local vm="$1"
  p0_guest "$vm" sh -c \
    'stat -c "%a:%u:%g" "$HOME"'
}

transport_probes() {
  local rc=0 ready=0 stopped=0 disconnect_command
  set +e
  p0_run_guest 1 "$P0_BUNDLE" "$P0_BUNDLE_HASH" bash -c \
    'test "$1" = "argument with spaces" && test "$2" = "$SUBYARD_E2E_VM"; exit 23' \
    _ 'argument with spaces' 1
  rc=$?
  set -e
  cleanup_guest 1 || die 'failed transport probe left its worktree behind'
  [ "$rc" = 23 ] || die "failed guest command returned $rc instead of 23"
  assert_no_worktrees

  command -v setsid >/dev/null 2>&1 || die 'setsid is required'
  PROBE_MARKER="/tmp/subyard-p0-disconnect-$TOKEN.ready"
  PROBE_NAME="subyard-p0-disconnect-$TOKEN"
  PROBE_LOG="$(mktemp /tmp/subyard-p0-disconnect.XXXXXX)"
  disconnect_command="$(quote_ssh_command runuser -u dev -- env HOME=/home/dev USER=dev LOGNAME=dev \
    bash -c \
    'printf "ready\n" > "$1"; exec -a "$2" sleep 300' \
    _ "$PROBE_MARKER" "$PROBE_NAME")"
  setsid ssh -F "$CONFIG" -T e2e-vm-1 -- "$disconnect_command" >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!
  for _ in $(seq 1 60); do
    if ssh -F "$CONFIG" -T e2e-vm-1 -- test -f "$PROBE_MARKER"; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = 1 ] || die 'disconnect probe did not start'
  kill -TERM -- "-$PROBE_PID"
  set +e
  wait "$PROBE_PID"
  rc=$?
  set -e
  PROBE_PID=''
  [ "$rc" -ne 0 ] || die 'interrupted runner returned success'
  for _ in $(seq 1 20); do
    if ! ssh -F "$CONFIG" -T e2e-vm-1 -- pgrep -f "^$PROBE_NAME 300$" >/dev/null 2>&1; then
      stopped=1
      break
    fi
    sleep 1
  done
  [ "$stopped" = 1 ] || die 'guest process survived controller disconnect'
  ssh -F "$CONFIG" -T e2e-vm-1 -- find "$PROBE_MARKER" -delete
  PROBE_MARKER=''
  PROBE_NAME=''
  find "$PROBE_LOG" -delete
  PROBE_LOG=''
  assert_no_worktrees
}

run_lanes() {
  local owner_pid controller_pid owner_rc controller_rc
  run_vm 1 owner & owner_pid=$!
  run_vm 2 controller & controller_pid=$!
  set +e
  wait "$owner_pid"; owner_rc=$?
  wait "$controller_pid"; controller_rc=$?
  set -e
  [ "$owner_rc" != 3 ] && [ "$controller_rc" != 3 ] || return 3
  [ "$owner_rc" != 2 ] && [ "$controller_rc" != 2 ] || return 2
  [ "$owner_rc" = 0 ] && [ "$controller_rc" = 0 ] || return 1
}

LOCAL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/subyard-agent-e2e.XXXXXX")"
acquire_lease
start_lease_keeper
CONFIG="$CLIENT_CONFIG"
[ -r "$CONFIG" ] || die 'lease-local SSH config is unavailable'
P0_BUNDLE="$LOCAL_TEMP/worktree.tar.gz"
build_bundle "$ROOT" "$P0_BUNDLE"
P0_BUNDLE_HASH="$(sha256sum "$P0_BUNDLE" | awk '{print $1}')"
CANDIDATE_HASH="$(public_tree_hash | sha256sum | awk '{print $1}')"
[[ "$CANDIDATE_HASH" =~ ^[0-9a-f]{64}$ ]] || die 'candidate tree hash is invalid'
printf '  [ .. ] exact public candidate sha256=%s\n' "$CANDIDATE_HASH"
# P0 fixtures use the token in local Unix account names and therefore retain their bounded
# numeric-token contract. Derive it from the lease identity instead of the retired allocation ID.
TOKEN="$((16#${LEASE_ID:0:8}))${LEASE_EPOCH}"
[[ "$TOKEN" =~ ^[0-9]+$ ]] || die 'lease token is invalid'
vm1_ip="$(ssh -F "$CONFIG" -G e2e-vm-1 | awk '$1=="hostname" {print $2; exit}')"
vm2_ip="$(ssh -F "$CONFIG" -G e2e-vm-2 | awk '$1=="hostname" {print $2; exit}')"

if [ "$PEERS_ONLY" = 0 ]; then
  for vm in 1 2; do
    snapshot="$(capacity_cache_snapshot "$vm")"
    IFS=$'\t' read -r DEFAULT_BUILD_CACHE_BEFORE[$vm] MODULE_CACHE_BEFORE[$vm] <<<"$snapshot"
    HOME_STATE_BEFORE[$vm]="$(home_state "$vm")"
    run_vm "$vm" capacity-preflight
  done
  start_capacity_monitors
  verify_boundary
  transport_probes
  run_lanes
  prepare_source_archive
  SOURCE_HOST_STARTED=1
  run_source_vm prepare "$SOURCE_ARCHIVE_REMOTE" "$SOURCE_HASH" "$SOURCE_COMMIT"
  p0_guest 1 \
    sh -c '[ ! -e "$1" ] || find "$1" -delete' _ "$SOURCE_ARCHIVE_REMOTE"
  SOURCE_ARCHIVE_REMOTE=''
  find "$SOURCE_ARCHIVE" -delete
  SOURCE_ARCHIVE=''
  reboot_vm1
  run_source_vm resume
  reboot_vm1
  run_source_vm finish
  SOURCE_HOST_STARTED=0
fi
VM1_YARD_ENTRY="$(yard_entry_state 1)"
VM2_YARD_ENTRY="$(yard_entry_state 2)"
VM1_SSH_STATE="$(ssh_state 1)"
VM2_SSH_STATE="$(ssh_state 2)"
PEERS_READY=1
run_vm 1 peer-prepare "$vm2_ip"
run_vm 2 peer-prepare "$vm1_ip"
peer1_info="$(direct_vm 1 peer-info)"
peer2_info="$(direct_vm 2 peer-info)"
peer1_key="$(awk -F '\t' '$1=="identity" {print $2; exit}' <<<"$peer1_info")"
peer2_key="$(awk -F '\t' '$1=="identity" {print $2; exit}' <<<"$peer2_info")"
vm1_host_key="$(awk -F '\t' '$1=="host" {print $2; exit}' <<<"$peer1_info")"
vm2_host_key="$(awk -F '\t' '$1=="host" {print $2; exit}' <<<"$peer2_info")"
[ -n "$peer1_key" ] && [ -n "$peer2_key" ] \
  && [ -n "$vm1_host_key" ] && [ -n "$vm2_host_key" ] \
  || die 'cross-owner synthetic SSH evidence is incomplete'
printf '  [ .. ] installing synthetic cross-owner SSH identities and host-key pins\n'
direct_vm 1 peer-authorize "$vm2_ip" "$peer2_key" "$vm2_host_key"
direct_vm 2 peer-authorize "$vm1_ip" "$peer1_key" "$vm1_host_key"
direct_vm 1 peer-probe "$vm2_ip"
direct_vm 2 peer-probe "$vm1_ip"
direct_vm 2 peer-yard-start
direct_vm 1 peer-projects "$vm2_ip"
direct_vm 2 peer-deny
direct_vm 1 peer-projects-offline "$vm2_ip"
direct_vm 2 peer-allow
direct_vm 1 peer-projects-finish "$vm2_ip"
direct_vm 1 peer-rpc "$vm2_ip"
direct_vm 2 peer-rpc "$vm1_ip"
direct_vm 1 peer-credentials "$vm2_ip"
clean_peers
PEERS_READY=0

for vm in 1 2; do
  ssh -F "$CONFIG" -T "e2e-vm-$vm" -- test ! -e "/tmp/subyard-p0-peer-$TOKEN" \
    || die "VM$vm retained its peer fixture"
  p0_guest "$vm" \
    sh -c '! grep -Fq "$1" "$HOME/.ssh/authorized_keys" 2>/dev/null' _ "subyard-p0-$TOKEN" \
    || die "VM$vm retained a synthetic peer authorization"
done
[ "$(yard_entry_state 1)" = "$VM1_YARD_ENTRY" ] \
  || die 'VM1 user yard entry was not restored exactly'
[ "$(yard_entry_state 2)" = "$VM2_YARD_ENTRY" ] \
  || die 'VM2 user yard entry was not restored exactly'
[ "$(ssh_state 1)" = "$VM1_SSH_STATE" ] \
  || die 'VM1 SSH state was not restored exactly'
[ "$(ssh_state 2)" = "$VM2_SSH_STATE" ] \
  || die 'VM2 SSH state was not restored exactly'
[ "$(public_tree_hash | sha256sum | awk '{print $1}')" = "$CANDIDATE_HASH" ] \
  || die 'public candidate changed during acceptance'
assert_no_worktrees
if [ "$PEERS_ONLY" = 0 ]; then
  run_vm 1 capacity-verify-cleanup
  run_vm 2 capacity-verify-cleanup
  for vm in 1 2; do
    [ "$(home_state "$vm")" = "${HOME_STATE_BEFORE[$vm]}" ] \
      || die "VM$vm operator home permissions or ownership changed"
  done
  assert_no_worktrees
  verify_cache_lifecycle
  capacity_report
  verify_boundary
  find "$CAPACITY_LOG_DIR" -depth -delete
  CAPACITY_LOG_DIR=''
fi
if [ "$PEERS_ONLY" = 1 ]; then
  printf 'ok: P0 two-owner inventory acceptance passed within one broker lease\n'
else
  printf 'ok: P0 two-VM acceptance passed within one broker lease\n'
fi
