#!/usr/bin/env bash
# Regression coverage for remote project inventory and target-aware removal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<<"$1" || fail "output does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" <<<"$1" || fail "output unexpectedly contains: $2"; }
assert_projects() {
  local output="$1" expected="$2" actual
  actual="$(awk '$1 == "remote" { print $6; exit }' <<<"$output")"
  [ "$actual" = "$expected" ] || fail "remote PROJECTS is '$actual', expected '$expected'"
}

mkdir -p "$TMP/bin" "$TMP/config/yards" "$TMP/config/yards/remote/projects" \
  "$TMP/shipped" "$TMP/subyard" "$TMP/state"
for f in agents.env host.env ports.env; do : > "$TMP/shipped/$f"; done
printf ': "${INSTANCE_NAME:=yard}"\n: "${INCUS_PROJECT:=subyard}"\n' > "$TMP/shipped/incus.project.env"
printf ': "${SSH_PORT:=2222}"\n' > "$TMP/shipped/subyard.env"

cat > "$TMP/bin/incus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  list) printf 'RUNNING\n' ;;
  exec)
    case "${YARD_META_MODE:-empty}" in
      one)
        printf '%s\n' \
          '{"schema":1,"projectId":"demo-12345678","name":"demo","mode":"sync"}' \
          '{"schema":1,"projectId":"demo-12345678","name":"duplicate","mode":"sync"}'
        ;;
      empty) exit 0 ;;
      fail) exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK
chmod 755 "$TMP/bin/incus"

cat > "$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [ "${1:-}" = -G ]; then
  printf 'hostname 127.0.0.1\nhostkeyalias subyard-remote-remote\n'
  exit 0
fi
if [[ "$joined" == *_info* ]]; then
  case "$(cat "$REMOTE_TEST_STATE/info-mode" 2>/dev/null || printf fail)" in
    one)  printf '%s\n' '{"state":"RUNNING","projects":1}' ;;
    null) printf '%s\n' '{"state":"RUNNING","projects":null}' ;;
    fail) exit 255 ;;
  esac
  exit 0
fi
if [[ "$joined" == *'_project-state'* ]]; then
  printf '%s\n' "$joined" >> "$REMOTE_TEST_STATE/owner-calls"
  exit 0
fi
if [[ "$joined" == *'yard-remote'*"'docker' 'info'"* ]]; then
  [ "$(cat "$REMOTE_TEST_STATE/cleanup-mode" 2>/dev/null || printf ok)" != fail ] || exit 1
  exit 0
fi
if [[ "$joined" == *'yard-remote'*"'docker' 'inspect'"* ]]; then
  exit 0
fi
if [[ "$joined" == *'yard-remote'*"'docker' 'rm'"* || "$joined" == *'/srv/env-secrets/'* ]]; then
  : > "$REMOTE_TEST_STATE/data-cleanup"
  exit 0
fi
if [[ "$joined" == *'yard-remote'*'/srv/workspaces/demo-12345678'* ]]; then
  : > "$REMOTE_TEST_STATE/workspace-delete"
  exit 0
fi
exit 0
MOCK
chmod 755 "$TMP/bin/ssh"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
chmod 0700 "$TMP/config/yards/remote/projects"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SUBYARD_CONFIG_DIR="$TMP/shipped"
export SUBYARD_NO_AUDIT=1
export REMOTE_TEST_STATE="$TMP/state"

cat > "$SUBYARD_CONFIG_HOME/yards/remote.env" <<'ENV'
YARD_TYPE=remote
REMOTE_DEST=owner
REMOTE_YARD=
SSH_PORT=2222
ENV

# Remote overview uses live yard inventory, retains the last numeric count when a fresh metadata
# observation is unavailable, and shows '-' when neither live nor cached inventory exists.
printf 'one\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/bin/yard yards)"
assert_projects "$output" 1
printf 'null\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/bin/yard yards)"
assert_projects "$output" 1
printf 'fail\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/bin/yard yards)"
assert_projects "$output" 1
rm -f "$SUBYARD_HOME/remote-remote.cache"
output="$($ROOT/bin/yard yards)"
assert_projects "$output" '-'

state_file="$SUBYARD_CONFIG_HOME/yards/remote/projects/demo-12345678.json"
write_state() {
  local target="$1"
  jq -n --arg target "$target" '{
    schema:1, projectId:"demo-12345678", name:"demo", hostPath:"/controller/demo",
    yardPath:"/srv/workspaces/demo-12345678/src", mode:"sync", sshHost:"yard-remote",
    importedAt:"test", target:$target
  }' > "$state_file"
  chmod 0600 "$state_file"
}
run_remove() {
  "$ROOT/bin/yard" -Y remote remove demo-12345678 "$@" --yes
}

# L1 removal has no L2 promise, warning, or owner-host cleanup call.
write_state yard
rm -f "$REMOTE_TEST_STATE/data-cleanup" "$REMOTE_TEST_STATE/workspace-delete"
output="$(run_remove --soft)"
assert_not_contains "$output" 'L2'
assert_not_contains "$output" 'box teardown'
[ ! -e "$REMOTE_TEST_STATE/data-cleanup" ] || fail 'L1 removal called L2 cleanup'
[ ! -e "$state_file" ] || fail 'native soft removal kept controller state'

# An in-yard L2 teardown failure is fatal before either controller state or workspace deletion.
write_state openclaw
printf 'fail\n' > "$REMOTE_TEST_STATE/cleanup-mode"
rm -f "$REMOTE_TEST_STATE/data-cleanup" "$REMOTE_TEST_STATE/workspace-delete" "$REMOTE_TEST_STATE/owner-calls"
if output="$(run_remove 2>&1)"; then fail 'remote L2 removal ignored in-yard teardown failure'; fi
assert_contains "$output" 'remove project environment before state'
[ -e "$state_file" ] || fail 'failed L2 teardown removed controller state'
[ ! -e "$REMOTE_TEST_STATE/workspace-delete" ] || fail 'failed L2 teardown deleted the workspace'
[ ! -e "$REMOTE_TEST_STATE/owner-calls" ] || fail 'failed L2 teardown changed owner state'

# Once in-yard cleanup succeeds, native removal commits state after the workspace is gone.
printf 'ok\n' > "$REMOTE_TEST_STATE/cleanup-mode"
rm -f "$REMOTE_TEST_STATE/owner-calls"
output="$(run_remove)"
assert_contains "$output" 'removed demo'
[ -e "$REMOTE_TEST_STATE/data-cleanup" ] || fail 'successful L2 removal skipped in-yard cleanup'
[ -e "$REMOTE_TEST_STATE/workspace-delete" ] || fail 'successful L2 removal skipped workspace deletion'
[ ! -e "$state_file" ] || fail 'native L2 removal kept controller state'
[ -s "$REMOTE_TEST_STATE/owner-calls" ] || fail 'native removal did not converge owner state'

printf 'ok: remote project counts are cached and native removal is target-aware\n'
