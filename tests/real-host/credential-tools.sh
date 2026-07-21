#!/usr/bin/env bash
# Opt-in real age/SOPS contract over two local synthetic peer ledgers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="${SUBYARD_REAL_KEYS_TOOLS_DIR:-}"
case "$TOOLS_DIR" in /*) ;; *) printf 'credential-tools: set SUBYARD_REAL_KEYS_TOOLS_DIR to an absolute pinned-tool directory\n' >&2; exit 2 ;; esac
for tool in age age-keygen sops; do
  [ -x "$TOOLS_DIR/bin/$tool" ] \
    || { printf 'credential-tools: missing executable %s/bin/%s\n' "$TOOLS_DIR" "$tool" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'credential-tools: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
export SUBYARD_KEYS_ROOT="$SUBYARD_CONFIG_HOME/key-hosts"
export SUBYARD_KEYS_TOOLS_DIR="$TOOLS_DIR"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR" "$SUBYARD_CONFIG_HOME/yards"

cat > "$SUBYARD_CONFIG_HOME/yards/one.env" <<EOF
SSH_PORT=3221
SUBYARD_KEYS_ROOT=$SUBYARD_KEYS_ROOT/one
SUBYARD_KEYS_CONSUMER_ROOT=$TMP/consumer-one
EOF
cat > "$SUBYARD_CONFIG_HOME/yards/two.env" <<EOF
SSH_PORT=3222
SUBYARD_KEYS_ROOT=$SUBYARD_KEYS_ROOT/two
SUBYARD_KEYS_CONSUMER_ROOT=$TMP/consumer-two
EOF

yard_one() { "$ROOT/bin/yard" -Y one "$@"; }
yard_two() { "$ROOT/bin/yard" -Y two "$@"; }
bootstrap_keys() {
  SUBYARD_YARD="$1" bash -c '
    set -euo pipefail
    root="$1"
    SCRIPT_DIR="$root/scripts"
    CONTROL_PLANE_ROOT="$root"
    . "$root/tests/helpers/source-control-plane.sh"
    . "$root/tests/helpers/source-credentials.sh"
    keys_init_store
  ' _ "$ROOT"
}

bootstrap_keys one >/dev/null
bootstrap_keys two >/dev/null
yard_one keys trust @two --yes >/dev/null

expected="$TMP/expected"
printf 'subyard-synthetic-real-crypto-fixture\n' > "$expected"
chmod 0600 "$expected"
yard_one keys add real-crypto --kind file --zone real-crypto --consumer staging-env --file "$expected" --yes >/dev/null
credential="$(yard_one keys list | awk -F '\t' '$8=="real-crypto" {print $1}')"
[ -n "$credential" ] || fail 'synthetic credential was not created'
record="$(find "$SUBYARD_KEYS_ROOT/one/shared/records/$credential" -type f -name '*.json' -print -quit)"
[ -n "$record" ] || fail 'encrypted revision is missing'
jq -e '.payload != "" and (.sops.age | length) == 2 and all(.sops.age[]; .recipient | startswith("age1"))' \
  "$record" >/dev/null || fail 'real SOPS output has an unexpected age envelope'
if grep -R -F -q -- 'subyard-synthetic-real-crypto-fixture' "$SUBYARD_KEYS_ROOT"; then
  fail 'synthetic plaintext reached the credential ledger'
fi

yard_one keys sync @two --now >/dev/null
yard_two keys materialize real-crypto --yes >/dev/null
cmp -s "$expected" "$TMP/consumer-two/config/staging/real-crypto.env" \
  || fail 'real age/SOPS payload did not decrypt on the trusted peer'
yard_one keys revoke "$credential" --yes >/dev/null
yard_one keys sync @two --now >/dev/null
yard_two keys materialize real-crypto --yes >/dev/null
[ ! -e "$TMP/consumer-two/config/staging/real-crypto.env" ] \
  || fail 'revoked synthetic credential remained materialized'

printf 'ok: real pinned age/SOPS encrypt, sync, decrypt and revoke contract\n'
