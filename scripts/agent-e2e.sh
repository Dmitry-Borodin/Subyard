#!/usr/bin/env bash
# agent-e2e.sh — copy the current public worktree to an allocated VM lab and run any command.
# This script never creates, starts, stops or deletes a yard, VM or inner Incus project.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"

WORKER="${SUBYARD_E2E_WORKER:-/usr/local/libexec/subyard/test-vms-inner}"
CONTROLLER_HOST="${SUBYARD_E2E_CONTROLLER_HOST:-yard-e2e-yard}"
CONTROLLER_USER="${SUBYARD_E2E_CONTROLLER_USER:-dev}"
HOST_KEY_ALIAS="${SUBYARD_E2E_HOST_KEY_ALIAS:-subyard-agent-e2e-yard}"
STATE_ROOT="${SUBYARD_E2E_STATE_DIR:-${SUBYARD_HOME:-$(subyard_operator_home)/.subyard}/e2e}"
KNOWN_HOSTS="$STATE_ROOT/known_hosts"
LOCAL_CONTROLLER=0
LOCAL_TEMP=""
PREPARED_DIRECTORY=""
declare -A GUEST_DIRS=()
declare -a SSH_OPTIONS=()

die() { printf 'agent-e2e: %s\n' "$*" >&2; exit 2; }
info() { printf '  [ .. ] %s\n' "$*"; }
ok() { printf '  [ ok ] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: scripts/agent-e2e.sh [--vm 1|2|both] -- COMMAND [ARG...]

Copies the current public worktree, including dirty and non-ignored untracked files, to each
selected VM in the already allocated e2e-yard lab. Runs COMMAND as dev with SUBYARD_E2E_VM set to
1 or 2, streams its output, and removes every run-specific guest directory on exit.

This command never runs yard start/stop or test-vms up/down.
EOF
}

controller() {
  if [ "$LOCAL_CONTROLLER" = 1 ]; then
    "$@"
  else
    ssh "${SSH_OPTIONS[@]}" "$CONTROLLER_USER@$CONTROLLER_HOST" -- "$@"
  fi
}

cleanup_guest() {
  local vm="$1" directory="${GUEST_DIRS[$1]:-}"
  [ -n "$directory" ] || return 0
  case "$directory" in /tmp/subyard-worktree.*) ;; *) return 1 ;; esac
  controller "$WORKER" exec "$vm" -- find "$directory" -depth -delete </dev/null
  unset 'GUEST_DIRS[$vm]'
}

cleanup_on_exit() {
  local rc=$? vm
  trap - EXIT INT TERM
  set +e
  for vm in "${!GUEST_DIRS[@]}"; do cleanup_guest "$vm" >/dev/null 2>&1; done
  if [ -n "$LOCAL_TEMP" ]; then
    case "$LOCAL_TEMP" in /tmp/subyard-agent-e2e.*|"${TMPDIR:-/tmp}"/subyard-agent-e2e.*)
      find "$LOCAL_TEMP" -depth -delete >/dev/null 2>&1
      ;;
    esac
  fi
  exit "$rc"
}

worktree_paths() {
  git ls-files --cached --others --exclude-standard -z
}

build_bundle() {
  local root="$1" bundle="$2" path resolved count=0
  local -a paths=()
  while IFS= read -r -d '' path; do
    # `git ls-files --cached` also reports tracked paths deleted from the dirty worktree. The
    # guest copy must mirror that deletion instead of asking tar to archive a missing file.
    if [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ]; then
      continue
    fi
    case "$path" in
      '' | /* | ../* | */../* | .git | .git/* | private | private/* | temp | temp/*)
        die "refusing non-public worktree path '$path'"
        ;;
    esac
    if [ -L "$root/$path" ]; then
      resolved="$(realpath "$root/$path")" || die "cannot resolve symlink '$path'"
      case "$resolved" in "$root"/*) ;; *) die "refusing symlink outside the worktree: '$path'" ;; esac
    fi
    paths+=("$path")
    count=$((count + 1))
  done < <(cd "$root" && worktree_paths)
  [ "$count" -gt 0 ] || die "public worktree is empty"
  printf '%s\0' "${paths[@]}" | tar -C "$root" --null -T - -czf "$bundle"
}

preflight_lab() {
  local status vm state ip seen=0
  status="$(controller "$WORKER" status </dev/null)" \
    || die "cannot query the allocated VM lab"
  while IFS=$'\t' read -r vm state ip; do
    case "$vm" in
      e2e-vm-1 | e2e-vm-2)
        [ "$state" = RUNNING ] && [ -n "$ip" ] && [ "$ip" != - ] \
          || die "$vm is not ready (state=$state, address=${ip:--})"
        seen=$((seen + 1))
        ;;
    esac
  done <<<"$status"
  [ "$seen" -eq 2 ] || die "expected exactly two ready managed VMs"
}

write_guest_command() {
  local vm="$1" directory="$2"; shift 2
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'cd %q\n' "$directory/src"
  printf 'export SUBYARD_E2E_VM=%q\n' "$vm"
  printf 'exec'
  printf ' %q' "$@"
  printf '\n'
}

prepare_guest() {
  local vm="$1" bundle="$2" expected_hash="$3" directory actual_hash
  directory="$(controller "$WORKER" exec "$vm" -- mktemp -d /tmp/subyard-worktree.XXXXXX </dev/null)" \
    || die "VM$vm did not create a run directory"
  case "$directory" in /tmp/subyard-worktree.*) ;; *) die "VM$vm returned an unsafe run directory" ;; esac
  GUEST_DIRS[$vm]="$directory"

  info "VM$vm: streaming current worktree" >&2
  controller "$WORKER" exec "$vm" -- dd "of=$directory/worktree.tar.gz" status=none < "$bundle" \
    || die "VM$vm worktree transfer failed"
  actual_hash="$(controller "$WORKER" exec "$vm" -- sha256sum "$directory/worktree.tar.gz" </dev/null \
    | awk '{print $1}')" || die "VM$vm checksum query failed"
  [ "$actual_hash" = "$expected_hash" ] || die "VM$vm worktree checksum mismatch"
  controller "$WORKER" exec "$vm" -- mkdir "$directory/src" </dev/null \
    || die "VM$vm source directory creation failed"
  controller "$WORKER" exec "$vm" -- tar -xzf "$directory/worktree.tar.gz" -C "$directory/src" </dev/null \
    || die "VM$vm worktree extraction failed"
  PREPARED_DIRECTORY="$directory"
}

run_guest() {
  local vm="$1" bundle="$2" expected_hash="$3" directory; shift 3
  prepare_guest "$vm" "$bundle" "$expected_hash" || return
  directory="$PREPARED_DIRECTORY"
  write_guest_command "$vm" "$directory" "$@" \
    | controller "$WORKER" exec "$vm" -- dd "of=$directory/run.sh" status=none \
    || die "VM$vm command transfer failed"
  controller "$WORKER" exec "$vm" -- chmod 0700 "$directory/run.sh" </dev/null \
    || die "VM$vm command preparation failed"
  printf '\n== e2e-vm-%s ==\n' "$vm"
  controller "$WORKER" exec "$vm" -- "$directory/run.sh" </dev/null
}

main() {
  local selector=both root bundle bundle_hash vm run_failed=0 cleanup_failed=0
  local -a selected=() command=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vm)
        [ "$#" -ge 2 ] || die "--vm needs 1, 2 or both"
        selector="$2"; shift 2
        ;;
      --) shift; command=("$@"); break ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown argument '$1' (put the guest command after --)" ;;
    esac
  done
  [ "${#command[@]}" -gt 0 ] || die "a guest command is required after --"
  case "$selector" in 1) selected=(1) ;; 2) selected=(2) ;; both) selected=(1 2) ;; *) die "--vm must be 1, 2 or both" ;; esac

  root="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "agent E2E must run from a Git worktree"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

  if [ -x "$WORKER" ]; then
    LOCAL_CONTROLLER=1
  else
    command -v ssh >/dev/null 2>&1 || die "ssh is required to reach $CONTROLLER_HOST"
    install -d -m 0700 "$STATE_ROOT"
    touch "$KNOWN_HOSTS"; chmod 0600 "$KNOWN_HOSTS"
    SSH_OPTIONS=(
      -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 -o ForwardAgent=no
      -o "HostKeyAlias=$HOST_KEY_ALIAS" -o "UserKnownHostsFile=$KNOWN_HOSTS"
      -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR
    )
  fi

  trap cleanup_on_exit EXIT INT TERM
  preflight_lab
  LOCAL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/subyard-agent-e2e.XXXXXX")"
  bundle="$LOCAL_TEMP/worktree.tar.gz"
  info "packing current public worktree"
  build_bundle "$root" "$bundle"
  bundle_hash="$(sha256sum "$bundle" | awk '{print $1}')"
  ok "worktree bundle ready (sha256=$bundle_hash)"

  for vm in "${selected[@]}"; do
    if ! run_guest "$vm" "$bundle" "$bundle_hash" "${command[@]}"; then run_failed=1; fi
    if ! cleanup_guest "$vm"; then
      printf 'agent-e2e: VM%s run directory cleanup failed\n' "$vm" >&2
      cleanup_failed=1
    fi
  done
  [ "$cleanup_failed" = 0 ] || return 3
  [ "$run_failed" = 0 ] || return 1
  ok "selected VM checks passed; run-specific worktrees removed"
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
