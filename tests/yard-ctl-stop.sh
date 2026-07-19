#!/usr/bin/env bash
# Regression: `yard stop` does not sever VS Code Remote-SSH unless explicitly forced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"
export MOCK_INCUS_LOG="$TMP/incus.log"
export MOCK_INCUS_STATE="$TMP/incus.state"
cat > "$TMP/bin/incus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  list) cat "$MOCK_INCUS_STATE" ;;
  exec)
    case "$*" in
      *'systemctl is-active'*)
        printf 'ssh-snapshot\n' >> "$MOCK_INCUS_LOG"
        [ "${MOCK_QUIESCE_RC:-0}" = 0 ] || exit "$MOCK_QUIESCE_RC"
        printf '%s\n' "${MOCK_QUIESCE_STATE:-snapshot:1:0}"
        ;;
      *'systemctl stop'*)
        printf 'ssh-quiesce\n' >> "$MOCK_INCUS_LOG"
        [ "${MOCK_STOP_LISTENER_RC:-0}" = 0 ] || exit "$MOCK_STOP_LISTENER_RC"
        ;;
      *'systemctl start'*)
        printf 'ssh-restore\n' >> "$MOCK_INCUS_LOG"
        case "$*" in
          *'systemctl start ssh.socket'*'systemctl start ssh'*)
            printf 'ssh-restore-order-ok\n' >> "$MOCK_INCUS_LOG"
            ;;
          *) printf 'ssh-restore-order-bad\n' >> "$MOCK_INCUS_LOG" ;;
        esac
        [ "${MOCK_RESTORE_RC:-0}" = 0 ] || exit "$MOCK_RESTORE_RC"
        ;;
      *)
        printf 'vscode-probe\n' >> "$MOCK_INCUS_LOG"
        [ "${MOCK_VSCODE_RC:-0}" = 0 ] || exit "$MOCK_VSCODE_RC"
        printf '%s\n' "${MOCK_VSCODE_STATE:-idle}"
        ;;
    esac
    ;;
  stop)
    printf 'stop\n' >> "$MOCK_INCUS_LOG"
    printf 'STOPPED\n' > "$MOCK_INCUS_STATE"
    ;;
  config)
    case "${2:-}" in
      get)
        case "${4:-}" in
          user.subyard.managed) printf 'true\n' ;;
          user.subyard.initialized) printf 'true\n' ;;
          user.subyard.desired_power) printf 'running\n' ;;
          boot.autostart) printf 'false\n' ;;
          user.subyard.bridge) printf 'incusbr0\n' ;;
        esac
        ;;
      set) printf 'set:%s=%s\n' "$4" "$5" >> "$MOCK_INCUS_LOG" ;;
      *) exit 90 ;;
    esac
    ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/bin/incus"
export PATH="$TMP/bin:$PATH"
export SUBYARD_CONFIG_LOADED=1
export SUBYARD_NO_AUDIT=1
export SUBYARD_HOME="$TMP/subyard"
export SUBYARD_CONFIG_HOME="$TMP/config"
export INCUS_PROJECT=test-project
export INSTANCE_NAME=test-yard
export DEV_USER=dev
export SSH_HOST=yard-test
export PROG=yard

reset_case() {
  printf 'RUNNING\n' > "$MOCK_INCUS_STATE"
  : > "$MOCK_INCUS_LOG"
  export MOCK_VSCODE_STATE=idle MOCK_VSCODE_RC=0 MOCK_QUIESCE_RC=0
  export MOCK_STOP_LISTENER_RC=0 MOCK_RESTORE_RC=0
  export MOCK_QUIESCE_STATE=snapshot:1:0
}

reset_case
MOCK_VSCODE_STATE=active
if "$ROOT/scripts/yard-ctl.sh" stop > "$TMP/out" 2>&1; then
  fail "stop accepted an active VS Code window"
fi
grep -Fq 'Close Remote Connection' "$TMP/out" \
  || fail "active-window failure has no repair guidance: $(tr '\n' ' ' < "$TMP/out")"
if grep -Fxq stop "$MOCK_INCUS_LOG"; then fail "active-window guard reached incus stop"; fi
grep -Fxq ssh-restore "$MOCK_INCUS_LOG" || fail "blocked stop did not restore the SSH listener"
grep -Fxq ssh-restore-order-ok "$MOCK_INCUS_LOG" \
  || fail "SSH socket was not restored before the service"
if grep -Fq 'user.subyard.desired_power=stopped' "$MOCK_INCUS_LOG"; then
  fail "blocked stop committed desired=stopped"
fi

reset_case
MOCK_VSCODE_STATE=active
"$ROOT/scripts/yard-ctl.sh" stop --force > "$TMP/out" 2>&1
grep -Fq 'bypasses the active SSH / VS Code update guard' "$TMP/out" \
  || fail "forced active stop emitted no warning"
grep -Fxq stop "$MOCK_INCUS_LOG" || fail "--force did not reach incus stop"
grep -Fxq 'set:user.subyard.desired_power=stopped' "$MOCK_INCUS_LOG" \
  || fail "--force did not commit desired=stopped"

reset_case
"$ROOT/scripts/yard-ctl.sh" stop > "$TMP/out" 2>&1
probe_line="$(grep -nFx vscode-probe "$MOCK_INCUS_LOG" | cut -d: -f1)"
quiesce_line="$(grep -nFx ssh-quiesce "$MOCK_INCUS_LOG" | cut -d: -f1)"
snapshot_line="$(grep -nFx ssh-snapshot "$MOCK_INCUS_LOG" | cut -d: -f1)"
stop_line="$(grep -nFx stop "$MOCK_INCUS_LOG" | cut -d: -f1)"
commit_line="$(grep -nFx 'set:user.subyard.desired_power=stopped' "$MOCK_INCUS_LOG" | cut -d: -f1)"
if [ "$snapshot_line" -ge "$quiesce_line" ] || [ "$quiesce_line" -ge "$probe_line" ] \
    || [ "$probe_line" -ge "$stop_line" ] \
    || [ "$stop_line" -ge "$commit_line" ]; then
  fail "idle stop did not run quiesce -> probe -> stop -> desired-state commit"
fi

reset_case
MOCK_VSCODE_RC=9
if "$ROOT/scripts/yard-ctl.sh" stop > "$TMP/out" 2>&1; then
  fail "stop accepted an unknown VS Code state"
fi
grep -Fq 'could not verify' "$TMP/out" || fail "unknown-state failure is unclear"
if grep -Fxq stop "$MOCK_INCUS_LOG"; then fail "unknown-state guard reached incus stop"; fi
grep -Fxq ssh-restore "$MOCK_INCUS_LOG" || fail "unknown-state stop did not restore SSH"

reset_case
MOCK_STOP_LISTENER_RC=9
if "$ROOT/scripts/yard-ctl.sh" stop > "$TMP/out" 2>&1; then
  fail "stop accepted a failed SSH-listener quiescence"
fi
grep -Fq 'could not pause new SSH connections' "$TMP/out" \
  || fail "listener-quiescence failure is unclear"
grep -Fxq ssh-restore "$MOCK_INCUS_LOG" \
  || fail "partial listener quiescence did not restore the original state"
if grep -Fxq stop "$MOCK_INCUS_LOG"; then fail "failed listener quiescence reached incus stop"; fi

printf 'STOPPED\n' > "$MOCK_INCUS_STATE"
: > "$MOCK_INCUS_LOG"
"$ROOT/scripts/yard-ctl.sh" stop > "$TMP/out" 2>&1
if grep -Fxq vscode-probe "$MOCK_INCUS_LOG"; then fail "already-stopped yard ran the VS Code probe"; fi

printf 'ok: yard stop protects active VS Code Remote-SSH state\n'
