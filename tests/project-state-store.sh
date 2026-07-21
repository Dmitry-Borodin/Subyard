#!/usr/bin/env bash
# Atomic project-state writes reject corrupt records and schema drift without replacing good data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
yard_valid_name() { [[ "${1:-}" =~ ^[a-z][a-z0-9-]*$ ]]; }

export SUBYARD_CONFIG_HOME="$TMP/config"
export SUBYARD_STATE_DIR="$TMP/config/projects"

# shellcheck source=scripts/state/store.sh
. "$ROOT/scripts/state/store.sh"

state_write demo-12345678 Demo /host/Demo /srv/workspaces/demo-12345678/src sync yard
state_set demo-12345678 target yard
record="$(state_file demo-12345678)"
[ "$(state_get demo-12345678 name)" = Demo ] || fail 'valid record was not readable'
[ "$(stat -c %a "$record")" = 600 ] || fail 'state record is not owner-only'
before="$(sha256sum "$record")"

# A rejected candidate may leave neither a partial final record nor a temporary candidate.
if state_write demo-12345678 Changed /bad /bad invalid yard >/dev/null 2>&1; then
  fail 'invalid candidate was reported as a successful write'
fi
[ "$(sha256sum "$record")" = "$before" ] || fail 'rejected write replaced the valid record'
if find "$SUBYARD_STATE_DIR" -maxdepth 1 -name '.*.json.tmp.*' -print -quit | grep -q .; then
  fail 'failed write leaked a partial candidate'
fi

cp "$record" "$TMP/good.json"
printf '{' > "$record"
if (state_get demo-12345678 name) >"$TMP/corrupt.out" 2>&1; then
  fail 'corrupt JSON was accepted'
fi
grep -Fq 'invalid project state' "$TMP/corrupt.out" || fail 'corrupt JSON diagnostic is not actionable'

cp "$TMP/good.json" "$record"
jq '.schema=2' "$record" > "$TMP/drift.json"
chmod 600 "$TMP/drift.json"
mv "$TMP/drift.json" "$record"
if (state_get demo-12345678 name) >"$TMP/schema.out" 2>&1; then
  fail 'unknown state schema was accepted'
fi
grep -Fq 'expected schema 1' "$TMP/schema.out" || fail 'schema drift diagnostic omits the expected version'

cp "$TMP/good.json" "$record"
jq '.projectId="other-12345678"' "$record" > "$TMP/mismatch.json"
chmod 600 "$TMP/mismatch.json"
mv "$TMP/mismatch.json" "$record"
if (state_get demo-12345678 name) >"$TMP/mismatch.out" 2>&1; then
  fail 'record/filename identity mismatch was accepted'
fi

printf 'ok: project state is schema-checked and atomically replaced\n'
