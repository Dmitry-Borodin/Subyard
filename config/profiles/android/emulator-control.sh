#!/usr/bin/env bash
# emulator-control.sh — own one detached Android Emulator process group inside the yard.
#
# The state stores the session leader PID plus its /proc start time. The pair protects stop/status
# from PID reuse; the negative PID targets only the setsid-created process group. flock makes two
# concurrent `yard emu up` calls converge on one launch.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
STATE_FILE="${SUBYARD_EMU_STATE_FILE:-/tmp/subyard-android-emu.state}"
LOCK_FILE="${SUBYARD_EMU_LOCK_FILE:-/tmp/subyard-android-emu.lock}"

die() { printf 'emulator-control: %s\n' "$*" >&2; exit 1; }

process_start_time() { # <pid>
  local raw rest
  IFS= read -r raw < "/proc/$1/stat" || return 1
  # Field 2 (comm) may contain spaces. Strip through its closing ')' first; starttime is
  # field 20 in the remaining field-3-and-later sequence.
  rest="${raw##*) }"
  # shellcheck disable=SC2086 # intentional split of the kernel's space-delimited stat fields
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s\n' "${20}"
}

STATE_PID=
STATE_START=
load_state() {
  STATE_PID=''
  STATE_START=''
  [ -r "$STATE_FILE" ] || return 1
  read -r STATE_PID STATE_START _ < "$STATE_FILE" || return 1
  case "$STATE_PID:$STATE_START" in
    *[!0-9:]* | :* | *:) return 1 ;;
  esac
  [ "$STATE_PID" -gt 1 ] 2>/dev/null || return 1
}

process_group_alive() { kill -0 -- "-$1" 2>/dev/null; }

state_is_live() {
  local current
  load_state || return 1
  if [ -e "/proc/$STATE_PID" ]; then
    current="$(process_start_time "$STATE_PID")" || return 1
    [ "$current" = "$STATE_START" ] || return 1
  fi
  # If the session leader exited but a child remains, its original process group still belongs
  # to this launch. Linux does not reuse that numeric ID while the group exists.
  process_group_alive "$STATE_PID"
}

lock_shared() {
  exec 9>"$LOCK_FILE"
  flock -s 9
}

lock_exclusive() {
  exec 9>"$LOCK_FILE"
  flock -x 9
}

cmd_run() { # <launcher> [args...] — internal, entered under setsid
  local launcher="${1:?launcher required}" start tmp
  shift
  start="$(process_start_time "$$")" || die "cannot read launcher start time"
  tmp="$STATE_FILE.$$"
  umask 077
  printf '%s %s\n' "$$" "$start" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  exec "$launcher" "$@"
}

cmd_start() { # <launcher> <log> [args...]
  [ "$#" -ge 2 ] || die 'start needs <launcher> <log> [args...]'
  local launcher="$1" log="$2" _i
  shift 2
  [ -x "$launcher" ] || die "launcher is not executable: $launcher"
  command -v flock >/dev/null 2>&1 || die "'flock' missing — provision the android profile"
  command -v setsid >/dev/null 2>&1 || die "'setsid' missing — provision the android profile"

  lock_exclusive
  if state_is_live; then
    printf 'already-running\n'
    return 0
  fi
  rm -f "$STATE_FILE"

  # Close the inherited lock fd in the child. The internal `run` writes state from inside the
  # new session, so the recorded PID is the actual process-group leader even if setsid forks.
  setsid "$SELF" run "$launcher" "$@" >"$log" 2>&1 </dev/null 9>&- &
  for _i in $(seq 1 40); do
    if state_is_live; then
      printf 'started\n'
      return 0
    fi
    sleep 0.05
  done
  die "launcher did not publish live state (see $log)"
}

cmd_is_running() {
  command -v flock >/dev/null 2>&1 || return 1
  lock_shared
  state_is_live
}

cmd_stop() {
  local _i pid
  command -v flock >/dev/null 2>&1 || die "'flock' missing — provision the android profile"
  lock_exclusive
  if ! state_is_live; then
    rm -f "$STATE_FILE"
    printf 'not-running\n'
    return 0
  fi
  pid="$STATE_PID"
  kill -TERM -- "-$pid" 2>/dev/null || true
  for _i in $(seq 1 50); do
    process_group_alive "$pid" || break
    sleep 0.1
  done
  if process_group_alive "$pid"; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    for _i in $(seq 1 20); do
      process_group_alive "$pid" || break
      sleep 0.05
    done
  fi
  process_group_alive "$pid" && die "process group $pid did not stop"
  rm -f "$STATE_FILE"
  printf 'stopped\n'
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  is-running) cmd_is_running ;;
  stop) cmd_stop ;;
  run) shift; cmd_run "$@" ;;
  *) die 'usage: emulator-control.sh start <launcher> <log> [args...] | is-running | stop' ;;
esac
