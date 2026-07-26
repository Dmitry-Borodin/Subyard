#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_CACHE_ROOT="${P0_CAPACITY_TEST_ROOT:-$HOME/.cache}"
install -d -m 0700 "$TEST_CACHE_ROOT"
TMP="$(mktemp -d "$TEST_CACHE_ROOT/subyard-p0-capacity-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP/home"
install -d -m 0700 "$HOME"
install -d -m 0700 "$TMP/bin"
PATH="$TMP/bin:$PATH"
export PATH
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[ "${1:-}" = env ] && [ "$#" = 2 ] || exit 2' \
  'case "$2" in' \
  '  GOCACHE) printf "%s/.cache/go-build\n" "$HOME" ;;' \
  '  GOMODCACHE) printf "%s/go/pkg/mod\n" "$HOME" ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$TMP/bin/go"
chmod 0700 "$TMP/bin/go"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# Keep this host-free unit isolated from any retained real-host Incus daemon.' \
  'exit 1' > "$TMP/bin/incus"
chmod 0700 "$TMP/bin/incus"

# shellcheck source=dev/e2e/lib-p0-capacity.sh
. "$ROOT/dev/e2e/lib-p0-capacity.sh"

p0_capacity_init 123
P0_E2E_MIN_ROOT_AVAILABLE_BYTES=1 \
P0_E2E_MIN_AVAILABLE_INODES=1 \
P0_E2E_MIN_TMP_SIZE_BYTES=1 \
P0_E2E_MIN_TMP_AVAILABLE_BYTES=1 \
  p0_capacity_preflight >/dev/null
[ "$GOCACHE" = "$HOME/.cache/subyard-p0-123/go-build" ] \
  || fail "P0 build cache is not allocation-scoped"
[ "$GOMODCACHE" = "$(env -u GOMODCACHE go env GOMODCACHE)" ] \
  || fail "P0 module cache is not the reusable Go cache"
[ "$(cat "$GOCACHE/.subyard-p0-marker")" = subyard-p0-123 ] \
  || fail "P0 build cache is not marker-owned"

subtree="$P0_CAPACITY_STATE_ROOT/fixture"
p0_capacity_prepare_subtree "$subtree"
printf 'payload\n' > "$subtree/data"
p0_capacity_remove_subtree "$subtree"
[ ! -e "$subtree" ] || fail "marker-owned subtree survived cleanup"
p0_capacity_remove_build_cache
[ ! -e "$P0_CAPACITY_STATE_ROOT" ] || fail "empty marker-owned root survived cleanup"

install -d -m 0700 "$P0_CAPACITY_STATE_ROOT"
printf 'foreign\n' > "$P0_CAPACITY_STATE_ROOT/data"
if (p0_capacity_prepare_root) >/dev/null 2>&1; then
  fail "non-empty unmarked P0 state was accepted"
fi
find "$P0_CAPACITY_STATE_ROOT" -depth -delete

if (p0_capacity_require_persistent_path /dev/shm fixture-tmpfs) >/dev/null 2>&1; then
  fail "tmpfs product state was accepted"
fi

printf 'ok: P0 capacity layout is persistent and marker-guarded\n'
