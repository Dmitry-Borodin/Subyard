#!/usr/bin/env bash
# `yard usage` dispatch, argument, exit-status, and repair-hint checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/public-config" "$tmp/config-home/yards" "$tmp/home"

export SUBYARD_CONFIG_DIR="$tmp/public-config"
export SUBYARD_CONFIG_HOME="$tmp/config-home"
export SUBYARD_HOME="$tmp/subyard-home"
export SUBYARD_NO_AUDIT=1
export INCUS_PROJECT=test-project
export INSTANCE_NAME=test-yard
export DEV_USER=dev
export INCUS_LOG="$tmp/incus.log"
export MOCK_ARGS_LOG="$tmp/args.log"
export MOCK_CCUSAGE_BIN="$tmp/mock-ccusage"
export FALLBACK_LOG="$tmp/fallback.log"

cat > "$tmp/bin/incus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  list) printf 'RUNNING\n' ;;
  exec)
    printf '%s\n' "$@" > "$INCUS_LOG"
    run="${!#}"
    run="${run//\/usr\/local\/bin\/ccusage/$MOCK_CCUSAGE_BIN}"
    exec /bin/bash -c "$run"
    ;;
  *) exit 90 ;;
esac
SH
cat > "$MOCK_CCUSAGE_BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: > "$MOCK_ARGS_LOG"
for arg in "$@"; do printf '%s\0' "$arg" >> "$MOCK_ARGS_LOG"; done
exit "${MOCK_CCUSAGE_EXIT:-0}"
SH
for command in npx bunx; do
  cat > "$tmp/bin/$command" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FALLBACK_LOG"
exit 99
SH
done
chmod +x "$tmp/bin/incus" "$MOCK_CCUSAGE_BIN" "$tmp/bin/npx" "$tmp/bin/bunx"
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC2016 # literal injection-shaped argument must survive unchanged
args=(daily --json 'space arg' '' '$(touch should-not-run)')
export MOCK_CCUSAGE_EXIT=23
set +e
"$ROOT/bin/yard" usage "${args[@]}" >"$tmp/stdout" 2>"$tmp/stderr"
rc=$?
set -e
[ "$rc" -eq 23 ] || fail "ccusage exit status was not preserved (got $rc)"

mapfile -d '' -t got < "$MOCK_ARGS_LOG"
[ "${#got[@]}" -eq "${#args[@]}" ] || fail "argument count changed across dispatch"
for i in "${!args[@]}"; do
  [ "${got[$i]}" = "${args[$i]}" ] || fail "argument $i changed across dispatch"
done
mapfile -t incus_args < "$INCUS_LOG"
if [ "${incus_args[5]:-}" != su ] \
  || [ "${incus_args[6]:-}" != - ] \
  || [ "${incus_args[7]:-}" != dev ] \
  || [ "${incus_args[8]:-}" != -c ]; then
  fail "ccusage was not launched through the dev login user"
fi

# Preserve named context in the repair hint.
cat > "$SUBYARD_CONFIG_HOME/yards/usage-test.env" <<'ENV'
YARD_TYPE=local
SSH_PORT=2299
ENV
export MOCK_CCUSAGE_BIN="$tmp/missing-ccusage"
export MOCK_CCUSAGE_EXIT=0
set +e
"$ROOT/bin/yard" -Y usage-test usage daily >"$tmp/missing.out" 2>"$tmp/missing.err"
missing_rc=$?
set -e
[ "$missing_rc" -eq 127 ] || fail "missing ccusage returned $missing_rc instead of 127"
grep -Fq 'repair with: yard -Y usage-test init' "$tmp/missing.err" \
  || fail "named-yard repair hint lost its context"
[ ! -e "$FALLBACK_LOG" ] || fail "missing ccusage invoked npx or bunx"
if grep -Eq 'bunx|npx|@latest' "$ROOT/scripts/yard-usage.sh"; then
  fail "runtime package fallback remains in yard-usage.sh"
fi

SUBYARD_USAGE_REPAIR_HINT='yard -Y controller init' \
  "$ROOT/bin/yard" usage >"$tmp/controller.out" 2>"$tmp/controller.err" || controller_rc=$?
[ "${controller_rc:-0}" -eq 127 ] || fail "controller repair case returned ${controller_rc:-0}"
grep -Fq 'repair with: yard -Y controller init' "$tmp/controller.err" \
  || fail "forwarded repair hint was ignored"

# Preserve the controller alias across remote forwarding.
cat > "$SUBYARD_CONFIG_HOME/yards/usage-remote.env" <<'ENV'
YARD_TYPE=remote
REMOTE_DEST=owner.test
REMOTE_YARD=inner
ENV
export SSH_LOG="$tmp/ssh.log"
cat > "$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SSH_LOG"
SH
chmod +x "$tmp/bin/ssh"
"$ROOT/bin/yard" -Y usage-remote usage >/dev/null
mapfile -d '' -t ssh_args < "$SSH_LOG"
payload="${ssh_args[-1]}"
decoded="$(/bin/bash -c "printf '%s' $payload")"
mkdir -p "$tmp/remote-bin"
export REMOTE_YARD_LOG="$tmp/remote-yard.log"
cat > "$tmp/remote-bin/yard" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "${SUBYARD_USAGE_REPAIR_HINT:-}" "$@" > "$REMOTE_YARD_LOG"
SH
chmod +x "$tmp/remote-bin/yard"
PATH="$tmp/remote-bin:$PATH" /bin/bash -c "$decoded"
mapfile -d '' -t remote_call < "$REMOTE_YARD_LOG"
[ "${remote_call[0]:-}" = 'yard -Y usage-remote init' ] || fail "remote repair hint lost controller alias"
if [ "${remote_call[1]:-}" != -Y ] \
  || [ "${remote_call[2]:-}" != inner ] \
  || [ "${remote_call[3]:-}" != usage ]; then
  fail "remote target command changed"
fi

printf 'ok: yard usage dispatch\n'
