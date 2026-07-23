#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="$ROOT/dev/agent-e2e.sh"
CONFIG=''
TOKEN=''
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
run_vm() {
  local vm="$1" mode="$2"; shift 2
  "$AGENT" --vm "$vm" -- bash dev/e2e/p0-guest.sh "$mode" "$TOKEN" "$@"
}
direct_vm() {
  local vm="$1" mode="$2"; shift 2
  "$AGENT" --ssh "$vm" -- env SUBYARD_E2E_VM="$vm" \
    bash "/tmp/subyard-p0-peer-$TOKEN/src/dev/e2e/p0-guest.sh" "$mode" "$TOKEN" "$@"
}
run_source_vm() {
  local mode="$1"; shift
  "$AGENT" --vm 1 -- bash dev/e2e/p0-source-upgrade.sh "$mode" "$TOKEN" "$@"
}
clean_peers() { "$AGENT" --vm both -- bash dev/e2e/p0-guest.sh peer-clean "$TOKEN"; }
clean_source_host() {
  run_source_vm clean
}
cleanup() {
  local rc=$? cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  if [ -n "$PROBE_PID" ]; then
    kill -TERM -- "-$PROBE_PID" >/dev/null 2>&1
    wait "$PROBE_PID" >/dev/null 2>&1
  fi
  if [ -n "$PROBE_NAME" ]; then
    "$AGENT" --ssh 1 -- pkill -f "^$PROBE_NAME 300$" >/dev/null 2>&1 || true
  fi
  if [ -n "$PROBE_MARKER" ]; then
    "$AGENT" --ssh 1 -- find "$PROBE_MARKER" -delete >/dev/null 2>&1 || cleanup_failed=1
  fi
  [ "$PEERS_READY" = 0 ] || clean_peers >/dev/null 2>&1 || cleanup_failed=1
  [ "$SOURCE_HOST_STARTED" = 0 ] || clean_source_host >/dev/null 2>&1 || cleanup_failed=1
  if [ -n "$SOURCE_ARCHIVE_REMOTE" ]; then
    "$AGENT" --ssh 1 -- \
      sh -c '[ ! -e "$1" ] || find "$1" -delete' _ "$SOURCE_ARCHIVE_REMOTE" \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  [ -z "$SOURCE_ARCHIVE" ] || [ ! -e "$SOURCE_ARCHIVE" ] \
    || find "$SOURCE_ARCHIVE" -delete >/dev/null 2>&1 \
    || cleanup_failed=1
  [ -z "$PROBE_LOG" ] || find "$PROBE_LOG" -delete >/dev/null 2>&1 || cleanup_failed=1
  [ "$cleanup_failed" = 0 ] || rc=3
  exit "$rc"
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
  "$AGENT" --ssh 1 -- \
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
  "$AGENT" --ssh "$vm" -- sh -c '
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
  "$AGENT" --ssh "$vm" -- sh -c '
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

transport_probes() {
  local rc=0 ready=0 stopped=0
  set +e
  "$AGENT" --vm 1 -- bash -c \
    'test "$1" = "argument with spaces" && test "$2" = "$SUBYARD_E2E_VM"; exit 23' \
    _ 'argument with spaces' 1
  rc=$?
  set -e
  [ "$rc" = 1 ] || die "failed guest command returned $rc instead of 1"
  assert_no_worktrees

  command -v setsid >/dev/null 2>&1 || die 'setsid is required'
  PROBE_MARKER="/tmp/subyard-p0-disconnect-$TOKEN.ready"
  PROBE_NAME="subyard-p0-disconnect-$TOKEN"
  PROBE_LOG="$(mktemp /tmp/subyard-p0-disconnect.XXXXXX)"
  setsid "$AGENT" --vm 1 -- bash -c \
    'printf "ready\n" > "$1"; exec -a "$2" sleep 300' \
    _ "$PROBE_MARKER" "$PROBE_NAME" >"$PROBE_LOG" 2>&1 &
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

CONFIG="$($AGENT --ssh-config)"
[ -r "$CONFIG" ] || die 'SSH config is unavailable'
CANDIDATE_HASH="$(public_tree_hash | sha256sum | awk '{print $1}')"
[[ "$CANDIDATE_HASH" =~ ^[0-9a-f]{64}$ ]] || die 'candidate tree hash is invalid'
printf '  [ .. ] exact public candidate sha256=%s\n' "$CANDIDATE_HASH"
before="$(ssh -F "$CONFIG" -T subyard-e2e-bastion </dev/null)" || die 'allocation is unavailable'
TOKEN="$(awk -F '\t' '$1=="allocation_id" {print $2}' <<<"$before")"
[[ "$TOKEN" =~ ^[0-9]+$ ]] || die 'allocation ID is invalid'
expires="$(awk -F '\t' '$1=="expires_at_epoch" {print $2}' <<<"$before")"
[[ "$expires" =~ ^[0-9]+$ ]] || die 'allocation expiry is invalid'
[ $((expires - $(date +%s))) -ge 1800 ] \
  || die 'allocation needs at least 30 minutes; ask the operator to refresh it'
vm1_ip="$(ssh -F "$CONFIG" -G e2e-vm-1 | awk '$1=="hostname" {print $2; exit}')"
vm2_ip="$(ssh -F "$CONFIG" -G e2e-vm-2 | awk '$1=="hostname" {print $2; exit}')"

"$AGENT" --verify-boundary
transport_probes
run_lanes
prepare_source_archive
SOURCE_HOST_STARTED=1
run_source_vm prepare "$SOURCE_ARCHIVE_REMOTE" "$SOURCE_HASH" "$SOURCE_COMMIT"
"$AGENT" --ssh 1 -- \
  sh -c '[ ! -e "$1" ] || find "$1" -delete' _ "$SOURCE_ARCHIVE_REMOTE"
SOURCE_ARCHIVE_REMOTE=''
find "$SOURCE_ARCHIVE" -delete
SOURCE_ARCHIVE=''
reboot_vm1
run_source_vm finish
SOURCE_HOST_STARTED=0
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
direct_vm 1 peer-rpc "$vm2_ip"
direct_vm 2 peer-rpc "$vm1_ip"
direct_vm 1 peer-credentials "$vm2_ip"
clean_peers
PEERS_READY=0

for vm in 1 2; do
  ssh -F "$CONFIG" -T "e2e-vm-$vm" -- test ! -e "/tmp/subyard-p0-peer-$TOKEN" \
    || die "VM$vm retained its peer fixture"
  "$AGENT" --ssh "$vm" -- \
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
"$AGENT" --verify-boundary
after="$(ssh -F "$CONFIG" -T subyard-e2e-bastion </dev/null)" || die 'final allocation status failed'
[ "$after" = "$before" ] || die 'acceptance changed allocation or TTL'

trap - EXIT INT TERM
printf 'ok: P0 two-VM acceptance passed without changing allocation\n'
