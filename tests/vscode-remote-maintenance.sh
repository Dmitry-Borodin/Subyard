#!/usr/bin/env bash
# Regression: remote extension maintenance is versioned, idle-only, and lock-aware.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
active_pid=''
lock_pid=''
cleanup() {
  [ -z "$active_pid" ] || kill "$active_pid" 2>/dev/null || true
  [ -z "$lock_pid" ] || kill "$lock_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP/home"
export MOCK_EXT_STATE="$TMP/extensions.state"
export MOCK_EXT_LOG="$TMP/extensions.log"
server_dir="$HOME/.vscode-server/cli/servers/Stable-test/server/bin"
mkdir -p "$server_dir"
cat > "$server_dir/code-server" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --list-extensions)
    cat "$MOCK_EXT_STATE"
    ;;
  --install-extension)
    spec="$2"
    printf '%s\n' "$*" >> "$MOCK_EXT_LOG"
    id="${spec%@*}"; version="${spec##*@}"
    awk -F@ -v wanted="$id" 'tolower($1) != tolower(wanted)' "$MOCK_EXT_STATE" \
      > "$MOCK_EXT_STATE.tmp"
    printf '%s@%s\n' "$id" "$version" >> "$MOCK_EXT_STATE.tmp"
    mv "$MOCK_EXT_STATE.tmp" "$MOCK_EXT_STATE"
    ;;
  *) exit 90 ;;
esac
SH
chmod +x "$server_dir/code-server"
printf 'openai.chatgpt@1.0.0\nanthropic.claude-code@2.0.0\n' > "$MOCK_EXT_STATE"
: > "$MOCK_EXT_LOG"

out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync \
  openai.chatgpt@1.1.0 anthropic.claude-code@2.0.0)"
case "$out" in updated:openai.chatgpt@1.1.0) ;; *) fail "unexpected update result: $out" ;; esac
grep -Fxq -- '--install-extension openai.chatgpt@1.1.0 --force' "$MOCK_EXT_LOG" \
  || fail "the stale extension was not force-installed at the local version"
grep -Fxq 'openai.chatgpt@1.1.0' "$MOCK_EXT_STATE" || fail "extension state did not converge"
[ "$(wc -l < "$MOCK_EXT_LOG")" -eq 1 ] || fail "an already-current extension was reinstalled"

out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync openai.chatgpt@1.1.0)"
[ "$out" = current ] || fail "idempotent sync was not current: $out"
[ "$(wc -l < "$MOCK_EXT_LOG")" -eq 1 ] || fail "idempotent sync performed another install"

printf 'openai.chatgpt@1.2.0\n' > "$MOCK_EXT_STATE"
out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync openai.chatgpt@1.1.0)"
[ "$out" = current ] || fail "a newer remote extension was not preserved: $out"
[ "$(wc -l < "$MOCK_EXT_LOG")" -eq 1 ] || fail "sync downgraded a newer remote extension"

printf 'openai.chatgpt@1.0.0\n' > "$MOCK_EXT_STATE"
out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync openai.chatgpt@1.0.0-beta.1)"
[ "$out" = current ] || fail "prerelease ordering was treated as safe to change: $out"
[ "$(wc -l < "$MOCK_EXT_LOG")" -eq 1 ] || fail "sync replaced a stable extension with a prerelease"

cat > "$HOME/.vscode-server/active-window" <<'SH'
#!/bin/sh
while :; do sleep 1; done
SH
chmod +x "$HOME/.vscode-server/active-window"
"$HOME/.vscode-server/active-window" --type=extensionHost &
active_pid=$!
for _ in $(seq 1 20); do
  out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" check-active)"
  [ "$out" != active ] || break
  sleep 0.05
done
[ "$out" = active ] || fail "an active extension host was not detected"
printf 'openai.chatgpt@1.0.0\n' > "$MOCK_EXT_STATE"
out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync openai.chatgpt@1.1.0)"
[ "$out" = busy ] || fail "sync did not defer to an active VS Code window: $out"
[ "$(wc -l < "$MOCK_EXT_LOG")" -eq 1 ] || fail "busy sync modified extensions"
kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
active_pid=''

lock="$HOME/.vscode-server/.subyard-extension-maintenance.lock"
: > "$lock"
flock "$lock" sh -c 'sleep 30' &
lock_pid=$!
for _ in $(seq 1 20); do
  out="$(sh "$ROOT/scripts/vscode-remote-maintenance.sh" check-active)"
  [ "$out" != updating ] || break
  sleep 0.05
done
[ "$out" = updating ] || fail "an in-flight extension update lock was not detected"
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
lock_pid=''

mkdir -p "$TMP/empty-home"
out="$(HOME="$TMP/empty-home" sh "$ROOT/scripts/vscode-remote-maintenance.sh" sync openai.chatgpt@1.1.0)"
[ "$out" = unavailable ] || fail "a first connection did not report an unavailable server"
out="$(VSCODE_USER=missing-user sh "$ROOT/scripts/vscode-remote-maintenance.sh" check-active)"
[ "$out" = unknown ] || fail "an unresolved VS Code user was reported as safely idle"

printf 'ok: VS Code remote maintenance is versioned, idle-only, and lock-aware\n'
