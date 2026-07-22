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

if SUBYARD_PREFLIGHT_BASE_PRESENT=0 MIN_DISK_GIB=999999 REC_DISK_GIB=999999 \
  "$ROOT/scripts/00-check-host.sh" \
  >"$TMP/fresh-low-space" 2>&1; then
  fail "fresh base-yard preflight accepted storage below its hard floor"
fi
SUBYARD_PREFLIGHT_BASE_PRESENT=1 MIN_DISK_GIB=999999 REC_DISK_GIB=999999 \
  "$ROOT/scripts/00-check-host.sh" >"$TMP/existing-low-space"
grep -Fq 'the base yard already exists, but new projects and profiles may need more space' \
  "$TMP/existing-low-space" || fail "resume preflight did not downgrade the base-yard floor"

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/incus" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'info yard --project subyard') exit 0 ;;
  '--version') printf '6.0.6\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/fake-bin/incus"
PATH="$TMP/fake-bin:$PATH" MIN_DISK_GIB=999999 REC_DISK_GIB=999999 \
  "$ROOT/scripts/00-check-host.sh" >"$TMP/auto-existing-low-space"
grep -Fq 'the base yard already exists, but new projects and profiles may need more space' \
  "$TMP/auto-existing-low-space" || fail "yard check did not detect its existing base yard"

printf 'ok: yard check uses the Incus storage path and init can resume an existing base yard\n'
