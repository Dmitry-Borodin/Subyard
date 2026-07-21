#!/usr/bin/env bash
# Remote project mutations must converge the owner host's registry, not only controller state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<<"$1" || fail "output does not contain: $2"; }
assert_json() { jq -e "$2" "$1" >/dev/null || fail "unexpected state in $1: $2"; }

mkdir -p "$TMP/bin" "$TMP/config/yards" "$TMP/shipped" "$TMP/subyard" "$TMP/state" "$TMP/home"
for f in agents.env host.env ports.env; do : > "$TMP/shipped/$f"; done
printf ': "${INSTANCE_NAME:=yard}"\n: "${INCUS_PROJECT:=subyard}"\n' > "$TMP/shipped/incus.project.env"
printf ': "${SSH_PORT:=2222}"\n' > "$TMP/shipped/subyard.env"

cat > "$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [ "${1:-}" = -G ]; then
  printf 'hostname 127.0.0.1\nhostkeyalias subyard-remote-remote\n'
  exit 0
fi
if [[ "$joined" == *'_project-state'* ]]; then
  printf '%s\n' "$joined" >> "$REGISTRY_TEST_STATE/owner-calls"
  [ ! -e "$REGISTRY_TEST_STATE/fail-owner" ]
  exit
fi
if [[ "$joined" == *'cat >'*'.subyard-meta.json'* ]]; then
  cat > "$REGISTRY_TEST_STATE/yard-meta.json"
  exit 0
fi
if [[ "$joined" == *'.subyard-meta.json'* ]]; then
  [ ! -e "$REGISTRY_TEST_STATE/live-meta.json" ] || cat "$REGISTRY_TEST_STATE/live-meta.json"
  exit 0
fi
exit 0
MOCK
chmod 755 "$TMP/bin/ssh"

cat > "$TMP/bin/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$REGISTRY_TEST_STATE/rsync-calls"
MOCK
chmod 755 "$TMP/bin/rsync"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SUBYARD_CONFIG_DIR="$TMP/shipped"
export SUBYARD_NO_AUDIT=1
export REGISTRY_TEST_STATE="$TMP/state"

# The hidden owner endpoint creates a yard-originated record without importing a foreign path.
owner_id='demo-12345678'
owner_state="$SUBYARD_CONFIG_HOME/projects/$owner_id.json"
"$ROOT/bin/yard" _project-state upsert "$owner_id" Demo sync openclaw
assert_json "$owner_state" \
  '.projectId == "demo-12345678" and .name == "Demo" and .mode == "sync" and
   .target == "openclaw" and .hostPath == "" and .yardPath == "/srv/workspaces/demo-12345678/src" and
   .sshHost == "yard" and .registrySource == "yard"'
output="$("$ROOT/bin/yard" list)"
assert_contains "$output" 'openclaw'
assert_contains "$output" '(yard)'

# A later foreign upsert may refresh mode/target, but must not erase a real owner-host source path.
jq '.hostPath="/owner/Demo"' "$owner_state" > "$owner_state.tmp" \
  && chmod 600 "$owner_state.tmp" && mv "$owner_state.tmp" "$owner_state"
"$ROOT/bin/yard" _project-state upsert "$owner_id" Demo git yard
assert_json "$owner_state" \
  '.hostPath == "/owner/Demo" and .mode == "git" and .target == "yard" and
   (has("registrySource") | not)'
"$ROOT/bin/yard" _project-state unregister "$owner_id"
[ -e "$owner_state" ] || fail 'foreign unregister removed a full owner-local record'

# Synthetic records are removed symmetrically, and validation cannot escape the state directory.
jq '.hostPath="" | .registrySource="yard"' "$owner_state" > "$owner_state.tmp" \
  && chmod 600 "$owner_state.tmp" && mv "$owner_state.tmp" "$owner_state"
"$ROOT/bin/yard" _project-state unregister "$owner_id"
[ ! -e "$owner_state" ] || fail 'foreign unregister kept its synthetic owner record'
if "$ROOT/bin/yard" _project-state upsert ../escape Bad sync yard >/dev/null 2>&1; then
  fail 'owner endpoint accepted an unsafe project id'
fi

# An explicit live scan repairs legacy projects that predate owner push and target metadata.
cat > "$REGISTRY_TEST_STATE/live-meta.json" <<'JSON'
{"schema":1,"projectId":"legacy-12345678","name":"Legacy","mode":"sync"}
{"schema":1,"projectId":"../escape","name":"Unsafe ID","mode":"sync","target":"yard"}
{"schema":1,"projectId":"unsafe-target-12345678","name":"Unsafe target","mode":"sync","target":"../../tmp"}
JSON
output="$("$ROOT/bin/yard" list --live 2>&1)"
legacy_state="$SUBYARD_CONFIG_HOME/projects/legacy-12345678.json"
[ -e "$legacy_state" ] || fail 'live list did not backfill legacy yard metadata'
assert_json "$legacy_state" \
  '.hostPath == "" and .yardPath == "/srv/workspaces/legacy-12345678/src" and
   .registrySource == "yard" and (has("target") | not)'
assert_contains "$output" 'Legacy'
assert_contains "$output" 'present'
assert_contains "$output" 'ignored invalid yard project metadata'
[ ! -e "$SUBYARD_CONFIG_HOME/escape.json" ] || fail 'live metadata escaped the project state directory'
[ ! -e "$SUBYARD_CONFIG_HOME/projects/unsafe-target-12345678.json" ] \
  || fail 'live metadata persisted an unsafe target'
output="$("$ROOT/bin/yard" list)"
assert_contains "$output" 'Legacy'
assert_contains "$output" '(yard)'
rm -f "$REGISTRY_TEST_STATE/live-meta.json"

# Named owner contexts write into their own registry and derive their local yard ssh alias.
cat > "$SUBYARD_CONFIG_HOME/yards/inner.env" <<'ENV'
SSH_PORT=3333
ENV
"$ROOT/bin/yard" -Y inner _project-state upsert named-12345678 Named sync yard
named_state="$SUBYARD_CONFIG_HOME/yards/inner/projects/named-12345678.json"
assert_json "$named_state" '.sshHost == "yard-inner" and .hostPath == "" and .target == "yard"'

# A remote controller maps to that named owner yard. Successful sync must push the owner upsert
# before publishing controller state, and portable yard metadata must carry the target too.
cat > "$SUBYARD_CONFIG_HOME/yards/remote.env" <<'ENV'
YARD_TYPE=remote
REMOTE_DEST=owner
REMOTE_YARD=inner
SSH_PORT=2222
ENV
mkdir -p "$TMP/projects/RemoteDemo"
printf 'demo\n' > "$TMP/projects/RemoteDemo/file.txt"
SUBYARD_YARD=remote SUBYARD_YARD_EXPLICIT=1 \
  "$ROOT/scripts/project-sync.sh" sync "$TMP/projects/RemoteDemo" --target yard --yes >/dev/null
remote_id="$(basename "$TMP/projects/RemoteDemo")-$(printf '%s' "$(realpath "$TMP/projects/RemoteDemo")" | sha256sum | cut -c1-8)"
remote_state="$SUBYARD_CONFIG_HOME/yards/remote/projects/$remote_id.json"
[ -e "$remote_state" ] || fail 'remote sync did not publish controller state'
owner_calls="$(cat "$REGISTRY_TEST_STATE/owner-calls")"
assert_contains "$owner_calls" 'yard\ -Y\ inner\ _project-state\ upsert'
assert_contains "$owner_calls" "$remote_id\\ RemoteDemo\\ sync\\ yard"
jq -e '.projectId == $id and .target == "yard"' --arg id "$remote_id" \
  "$REGISTRY_TEST_STATE/yard-meta.json" >/dev/null || fail 'yard metadata omitted the project target'

# Remote clone follows the same owner convergence path and preserves its L2 target in both calls.
: > "$REGISTRY_TEST_STATE/owner-calls"
SUBYARD_YARD=remote SUBYARD_YARD_EXPLICIT=1 \
  "$ROOT/scripts/project-clone.sh" https://example.invalid/repo.git ForeignClone \
    --target openclaw --yes >/dev/null
clone_id="ForeignClone-$(printf '%s' https://example.invalid/repo.git | sha256sum | cut -c1-8)"
clone_state="$SUBYARD_CONFIG_HOME/yards/remote/projects/$clone_id.json"
[ -e "$clone_state" ] || fail 'remote clone did not publish controller state'
assert_json "$clone_state" '.mode == "git" and .target == "openclaw"'
owner_calls="$(cat "$REGISTRY_TEST_STATE/owner-calls")"
assert_contains "$owner_calls" 'yard\ -Y\ inner\ _project-state\ upsert'
assert_contains "$owner_calls" "$clone_id\\ ForeignClone\\ git\\ openclaw"
jq -e '.projectId == $id and .mode == "git" and .target == "openclaw"' --arg id "$clone_id" \
  "$REGISTRY_TEST_STATE/yard-meta.json" >/dev/null || fail 'clone metadata omitted its target'

# If the owner rejects convergence, the copied workspace may exist but controller state must not
# claim the operation completed; re-running the same explicit sync can repair it.
mkdir -p "$TMP/projects/Rejected"
: > "$REGISTRY_TEST_STATE/fail-owner"
if SUBYARD_YARD=remote SUBYARD_YARD_EXPLICIT=1 \
  "$ROOT/scripts/project-sync.sh" sync "$TMP/projects/Rejected" --yes >"$TMP/rejected.out" 2>&1; then
  fail 'remote sync succeeded despite owner registry failure'
fi
rejected_id="Rejected-$(printf '%s' "$(realpath "$TMP/projects/Rejected")" | sha256sum | cut -c1-8)"
[ ! -e "$SUBYARD_CONFIG_HOME/yards/remote/projects/$rejected_id.json" ] \
  || fail 'failed owner convergence left completed controller state'
assert_contains "$(cat "$TMP/rejected.out")" 'owner-host registry was not updated'
rm -f "$REGISTRY_TEST_STATE/fail-owner"

# Remote removal unregisters the synthetic owner record before dropping controller state.
: > "$REGISTRY_TEST_STATE/owner-calls"
SUBYARD_YARD=remote SUBYARD_YARD_EXPLICIT=1 \
  "$ROOT/scripts/project-remove.sh" "$remote_id" --soft --yes >/dev/null
[ ! -e "$remote_state" ] || fail 'remote remove kept controller state'
owner_calls="$(cat "$REGISTRY_TEST_STATE/owner-calls")"
assert_contains "$owner_calls" 'yard\ -Y\ inner\ _project-state\ unregister'
assert_contains "$owner_calls" "$remote_id"

printf 'ok: remote project mutations converge the owner-host registry\n'
