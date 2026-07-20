#!/usr/bin/env bash
# Credential DAG/conflict policy is usable with injected ports and has no concrete tool globals.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

domain="$ROOT/scripts/credentials/domain.sh"
if grep -En '(^|[^A-Za-z0-9_])KEYS_[A-Z0-9_]*([^A-Za-z0-9_]|$)' "$domain" >/dev/null \
  || grep -Ein '(^|[^A-Za-z0-9_])(sops|git|ssh)([^A-Za-z0-9_]|$)' "$domain" >/dev/null; then
  fail 'credential domain references a shell-global or concrete crypto/Git/SSH adapter'
fi

credential_json() { jq "$@"; }
keys_record_files() { find "$1/records/$2" -type f -name '*.json' -print | sort; }
# shellcheck source=scripts/credentials/domain.sh
. "$domain"

mkdir -p "$TMP/repo/records/cred-fixture"
cat > "$TMP/repo/records/cred-fixture/a.json" <<'JSON'
{"revisionId":"a","parents":[],"actorId":"one","actorCounter":1,"label":"x","kind":"opaque","zone":"test","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["one","two"],"state":"active","exclusive":false,"syncable":true}
JSON
cat > "$TMP/repo/records/cred-fixture/b.json" <<'JSON'
{"revisionId":"b","parents":["a"],"actorId":"one","actorCounter":2,"label":"x","kind":"opaque","zone":"test","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["one","two"],"state":"active","exclusive":false,"syncable":true}
JSON
cat > "$TMP/repo/records/cred-fixture/c.json" <<'JSON'
{"revisionId":"c","parents":["a"],"actorId":"two","actorCounter":1,"label":"x","kind":"opaque","zone":"test","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["two","three"],"state":"active","exclusive":false,"syncable":true}
JSON

heads="$(keys_heads_json "$TMP/repo" cred-fixture)"
[ "$(printf '%s' "$heads" | jq -r '[.[].revisionId] | sort | join(" ")')" = 'b c' ] \
  || fail 'revision DAG did not retain both concurrent heads'
keys_metadata_compatible "$heads" || fail 'compatible concurrent metadata was rejected'
[ "$(keys_recipient_intersection "$heads" | jq -r 'join(" ")')" = two ] \
  || fail 'recipient intersection policy drifted'

printf 'ok: credential DAG policy is adapter-injected and conflict-aware\n'
