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
if [[ "$joined" == *'shell'*'--root'* ]]; then
  [ "$(cat "$REMOTE_TEST_STATE/cleanup-mode" 2>/dev/null || printf ok)" != fail ] || exit 1
  : > "$REMOTE_TEST_STATE/owner-cleanup"
  exit 0
fi
if [[ "$joined" == *'yard-remote'*'rm -rf'* ]]; then
  : > "$REMOTE_TEST_STATE/workspace-delete"
  exit 0
fi
exit 0
MOCK
chmod 755 "$TMP/bin/ssh"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SUBYARD_CONFIG_DIR="$TMP/shipped"
export SUBYARD_NO_AUDIT=1
export REMOTE_TEST_STATE="$TMP/state"

# `_info` ignores empty owner-host state and counts unique live yard metadata. A successful empty
# scan is zero; a failed scan is unknown (null), never a made-up zero.
info="$(YARD_META_MODE=one "$ROOT/scripts/yard-info.sh")"
jq -e '.projects == 1' <<<"$info" >/dev/null || fail '_info did not report one unique live project'
info="$(YARD_META_MODE=empty "$ROOT/scripts/yard-info.sh")"
jq -e '.projects == 0' <<<"$info" >/dev/null || fail '_info did not report a successful empty scan as zero'
info="$(YARD_META_MODE=fail "$ROOT/scripts/yard-info.sh")"
jq -e '.projects == null' <<<"$info" >/dev/null || fail '_info did not report a failed scan as null'

cat > "$SUBYARD_CONFIG_HOME/yards/remote.env" <<'ENV'
YARD_TYPE=remote
REMOTE_DEST=owner
REMOTE_YARD=
SSH_PORT=2222
ENV

# Remote overview uses live yard inventory, retains the last numeric count when a fresh metadata
# observation is unavailable, and shows '-' when neither live nor cached inventory exists.
printf 'one\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/scripts/yard-yards.sh)"
assert_projects "$output" 1
printf 'null\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/scripts/yard-yards.sh)"
assert_projects "$output" 1
printf 'fail\n' > "$REMOTE_TEST_STATE/info-mode"
output="$($ROOT/scripts/yard-yards.sh)"
assert_projects "$output" 1
rm -f "$SUBYARD_HOME/remote-remote.cache"
output="$($ROOT/scripts/yard-yards.sh)"
assert_projects "$output" '-'

state_file="$SUBYARD_CONFIG_HOME/yards/remote/projects/demo-12345678.json"
write_state() {
  local target="$1"
  jq -n --arg target "$target" '{
    schema:1, projectId:"demo-12345678", name:"demo", hostPath:"/controller/demo",
    yardPath:"/srv/workspaces/demo-12345678/src", mode:"sync", sshHost:"yard-remote",
    importedAt:"test", target:$target
  }' > "$state_file"
}
run_remove() {
  SUBYARD_YARD=remote SUBYARD_YARD_EXPLICIT=1 \
    "$ROOT/scripts/project-remove.sh" demo-12345678 "$@" --yes
}

# L1 removal has no L2 promise, warning, or owner-host cleanup call.
write_state yard
rm -f "$REMOTE_TEST_STATE/owner-cleanup" "$REMOTE_TEST_STATE/workspace-delete"
output="$(run_remove --soft)"
assert_not_contains "$output" 'L2'
assert_not_contains "$output" 'box teardown'
[ ! -e "$REMOTE_TEST_STATE/owner-cleanup" ] || fail 'L1 removal called owner-host L2 cleanup'
[ ! -e "$state_file" ] || fail 'L1 removal kept controller state'

# An owner-host L2 teardown failure is fatal before either controller state or workspace deletion.
write_state openclaw
printf 'fail\n' > "$REMOTE_TEST_STATE/cleanup-mode"
rm -f "$REMOTE_TEST_STATE/owner-cleanup" "$REMOTE_TEST_STATE/workspace-delete"
if output="$(run_remove 2>&1)"; then fail 'remote L2 removal ignored owner-host teardown failure'; fi
assert_contains "$output" 'project state and workspace were kept'
[ -e "$state_file" ] || fail 'failed L2 teardown removed controller state'
[ ! -e "$REMOTE_TEST_STATE/workspace-delete" ] || fail 'failed L2 teardown deleted the workspace'

# Once owner cleanup succeeds, full removal proceeds in order and drops both workspace and state.
printf 'ok\n' > "$REMOTE_TEST_STATE/cleanup-mode"
output="$(run_remove)"
assert_contains "$output" 'removed remote L2 box/staged env'
[ -e "$REMOTE_TEST_STATE/owner-cleanup" ] || fail 'successful L2 removal skipped owner cleanup'
[ -e "$REMOTE_TEST_STATE/workspace-delete" ] || fail 'successful L2 removal skipped workspace deletion'
[ ! -e "$state_file" ] || fail 'successful L2 removal kept controller state'

printf 'ok: remote project counts are live/cached and removal is target-aware\n'
