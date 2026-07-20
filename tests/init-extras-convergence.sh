#!/usr/bin/env bash
# Extras probe detects missing, stale and property-drifted YARD_* state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_PROFILES_DIR="$TMP/profiles"
export SUBYARD_CONFIG_LOADED=1
export SUBYARD_NO_AUDIT=1
export PATH="$TMP/bin:$PATH"
mkdir -p "$HOME" "$SUBYARD_PROFILES_DIR/fixture" "$TMP/bin"
printf 'YARD_MOUNTS="cache:/srv/cache:rw:0755"\n' > "$SUBYARD_PROFILES_DIR/fixture/profile.conf"

export MOCK_DEVICES=yx-cache
export MOCK_SOURCE="$HOST_BASE/cache"
export MOCK_PATH=/srv/cache
export MOCK_READONLY=false
export MOCK_SHIFT=true
export MOCK_IDMAP=''
export MOCK_MKNOD=''
export MOCK_SETXATTR=''
cat > "$TMP/bin/incus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  'info  ' | 'info yard --project') exit 0 ;;
  'config device list') tr ' ' '\n' <<<"$MOCK_DEVICES" ;;
  'config device get')
    case "${6:-}" in
      type) printf 'disk\n' ;;
      source) printf '%s\n' "$MOCK_SOURCE" ;;
      path) printf '%s\n' "$MOCK_PATH" ;;
      readonly) printf '%s\n' "$MOCK_READONLY" ;;
      shift) printf '%s\n' "$MOCK_SHIFT" ;;
    esac ;;
  'config get yard')
    case "${4:-}" in
      security.idmap.size) printf '%s\n' "$MOCK_IDMAP" ;;
      security.syscalls.intercept.mknod) printf '%s\n' "$MOCK_MKNOD" ;;
      security.syscalls.intercept.setxattr) printf '%s\n' "$MOCK_SETXATTR" ;;
    esac ;;
  *) printf 'unexpected incus call: %s\n' "$*" >&2; exit 90 ;;
esac
MOCK
chmod +x "$TMP/bin/incus"

# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"

have_extras || fail "matching extras rejected"
MOCK_DEVICES='yx-cache yx-stale'
! have_extras || fail "stale yx-* device accepted"
MOCK_DEVICES=''
! have_extras || fail "missing desired extra accepted"
MOCK_DEVICES=yx-cache
MOCK_PATH=/wrong
! have_extras || fail "drifted extra mount accepted"

# No declarations is still a desired state: stale devices and extras-owned capability keys must
# keep the stage pending until the reconciler removes the final extra.
: > "$SUBYARD_PROFILES_DIR/fixture/profile.conf"
MOCK_DEVICES=yx-last
MOCK_IDMAP=1000000
MOCK_MKNOD=true
MOCK_SETXATTR=true
! have_extras || fail "stale final extra accepted with an empty desired set"
MOCK_DEVICES=''
MOCK_IDMAP=''
MOCK_MKNOD=''
MOCK_SETXATTR=''
have_extras || fail "empty desired/live extras state rejected"

printf 'ok: init extras probe detects desired/live drift\n'
