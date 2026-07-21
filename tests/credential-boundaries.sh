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

credential='cred-0123456789abcdef0123456789abcdef'
mkdir -p "$TMP/repo/records/$credential"
cat > "$TMP/repo/records/$credential/one-000000000001-aaaaaaaa.json" <<'JSON'
{"schemaVersion":1,"credentialId":"cred-0123456789abcdef0123456789abcdef","revisionId":"one-000000000001-aaaaaaaa","parents":[],"actorId":"one","actorCounter":1,"label":"x","kind":"opaque","zone":"test","scope":"staging","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["one","two"],"state":"active","exclusive":false,"syncable":true,"timestamp":"2026-07-21T00:00:00Z"}
JSON
cat > "$TMP/repo/records/$credential/one-000000000002-bbbbbbbb.json" <<'JSON'
{"schemaVersion":1,"credentialId":"cred-0123456789abcdef0123456789abcdef","revisionId":"one-000000000002-bbbbbbbb","parents":["one-000000000001-aaaaaaaa"],"actorId":"one","actorCounter":2,"label":"x","kind":"opaque","zone":"test","scope":"staging","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["one","two"],"state":"active","exclusive":false,"syncable":true,"timestamp":"2026-07-21T00:00:01Z"}
JSON
cat > "$TMP/repo/records/$credential/two-000000000001-cccccccc.json" <<'JSON'
{"schemaVersion":1,"credentialId":"cred-0123456789abcdef0123456789abcdef","revisionId":"two-000000000001-cccccccc","parents":["one-000000000001-aaaaaaaa"],"actorId":"two","actorCounter":1,"label":"x","kind":"opaque","zone":"test","scope":"staging","consumer":"none","authorityHost":"","assignedYard":"","assignmentEpoch":0,"recipientActors":["two","three"],"state":"active","exclusive":false,"syncable":true,"timestamp":"2026-07-21T00:00:02Z"}
JSON

heads="$(keys_heads_json "$TMP/repo" "$credential")"
[ "$(printf '%s' "$heads" | jq -r '[.[].revisionId] | sort | join(" ")')" = \
  'one-000000000002-bbbbbbbb two-000000000001-cccccccc' ] \
  || fail 'revision DAG did not retain both concurrent heads'
keys_metadata_compatible "$heads" || fail 'compatible concurrent metadata was rejected'
[ "$(keys_recipient_intersection "$heads" | jq -r 'join(" ")')" = two ] \
  || fail 'recipient intersection policy drifted'

printf 'ok: credential DAG policy is adapter-injected and conflict-aware\n'
