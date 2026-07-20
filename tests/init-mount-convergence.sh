#!/usr/bin/env bash
# Init mount probe detects missing, stale and property-drifted host mounts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
mkdir -p "$HOME"

# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"
reconcile_incus_reachable() { return 0; }
HOST_MOUNTS='host-cache:/mnt/host/cache:rw:0755'
MOCK_DEVICES=host-cache
MOCK_SOURCE="$HOST_BASE/host-cache"
MOCK_PATH=/mnt/host/cache
MOCK_READONLY=false
incus() {
  case "${1:-} ${2:-} ${3:-}" in
    'config device list') printf '%s\n' $MOCK_DEVICES ;;
    'config device get')
      case "${6:-}" in
        source) printf '%s\n' "$MOCK_SOURCE" ;;
        path) printf '%s\n' "$MOCK_PATH" ;;
        readonly) printf '%s\n' "$MOCK_READONLY" ;;
      esac ;;
  esac
}

stage_mounts_check || fail "matching desired/live mount rejected"
MOCK_DEVICES='host-cache host-old'
! stage_mounts_check || fail "stale host-* mount accepted"
MOCK_DEVICES=''
! stage_mounts_check || fail "missing desired mount accepted"
MOCK_DEVICES=host-cache
MOCK_SOURCE="$HOST_BASE/other"
! stage_mounts_check || fail "drifted mount source accepted"
MOCK_SOURCE="$HOST_BASE/host-cache"
MOCK_READONLY=true
! stage_mounts_check || fail "drifted readonly flag accepted"

printf 'ok: init mount convergence is bidirectional and property-aware\n'
