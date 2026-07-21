#!/usr/bin/env bash
# Real process-group integration for the in-yard emulator controller.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$ROOT/config/profiles/android/emulator-control.sh"
TMP="$(mktemp -d)"
STATE="$TMP/emulator.state"
LOCK="$TMP/emulator.lock"
LOG="$TMP/emulator.log"
tracked_pid=
unrelated_pid=

cleanup() {
  [ -z "$tracked_pid" ] || kill -KILL -- "-$tracked_pid" 2>/dev/null || true
  [ -z "$unrelated_pid" ] || kill -KILL -- "-$unrelated_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TMP/fake-emulator" <<'FAKE'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
FAKE
chmod 755 "$TMP/fake-emulator"

control() {
  SUBYARD_EMU_STATE_FILE="$STATE" SUBYARD_EMU_LOCK_FILE="$LOCK" \
    "$CONTROL" "$@"
}

# Two simultaneous starts must create exactly one detached process group.
control start "$TMP/fake-emulator" "$LOG" > "$TMP/start-a" & start_a=$!
control start "$TMP/fake-emulator" "$LOG" > "$TMP/start-b" & start_b=$!
wait "$start_a"
wait "$start_b"
[ "$(grep -hxc started "$TMP/start-a" "$TMP/start-b" | awk '{s += $1} END {print s}')" = 1 ] \
  || fail 'concurrent starts did not produce exactly one launcher'
[ "$(grep -hxc already-running "$TMP/start-a" "$TMP/start-b" | awk '{s += $1} END {print s}')" = 1 ] \
  || fail 'concurrent starts did not converge on the existing launcher'

control is-running || fail 'controller lost its live process group'
read -r tracked_pid _ < "$STATE"
kill -0 "$tracked_pid" 2>/dev/null || fail 'recorded session leader is not alive'
[ "$(control start "$TMP/fake-emulator" "$LOG")" = already-running ] \
  || fail 'idempotent start did not reuse the tracked process group'
[ "$(control stop)" = stopped ] || fail 'controller did not stop its process group'
kill -0 -- "-$tracked_pid" 2>/dev/null && fail 'tracked process group survived stop'
tracked_pid=
[ ! -e "$STATE" ] || fail 'stop left process state behind'

# A stale/reused PID record must never authorize signalling an unrelated process group.
setsid bash -c 'exec -a "shellcheck -x emulator-run.sh" sleep 30' >/dev/null 2>&1 &
unrelated_pid=$!
printf '%s %s\n' "$unrelated_pid" 1 > "$STATE"
if control is-running; then fail 'stale start time was accepted as live state'; fi
[ "$(control stop)" = not-running ] || fail 'stale state was not discarded'
kill -0 "$unrelated_pid" 2>/dev/null || fail 'stop signalled an unrelated process group'
kill -TERM -- "-$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=

printf 'ok: emulator controller serializes start and owns only its recorded process group\n'
