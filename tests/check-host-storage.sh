#!/usr/bin/env bash
# Standalone `yard check` and init preflight resolve the same Incus storage filesystem.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'MIN_DISK_GIB="${MIN_DISK_GIB:-5}"' "$ROOT/scripts/00-check-host.sh" \
  || fail "default base-yard storage floor is not 5 GiB"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
unset STORAGE_PATH SUBYARD_CONFIG_LOADED
export SUBYARD_CONFIG_DIR="$TMP/config"
export MIN_DISK_GIB=0
export REC_DISK_GIB=0
mkdir -p "$SUBYARD_HOME"
cp -a "$ROOT/config" "$SUBYARD_CONFIG_DIR"

"$ROOT/scripts/00-check-host.sh" >"$TMP/output"
expected="$SUBYARD_HOME/incus/storage"
grep -Fq "Storage ($expected):" "$TMP/output" \
  || fail "yard check did not use the configured Incus storage path"

printf 'ok: yard check uses the Incus storage path\n'
