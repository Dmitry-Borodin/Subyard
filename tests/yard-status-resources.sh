#!/usr/bin/env bash
# Regression: resource probes must not consume the active-profile iterator's stdin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"

# A real `incus exec` may attach to and consume inherited stdin. Model that behavior for every
# in-yard probe: before the fix, the emulator probe drained the remaining profile names.
incus() {
  case "$1" in
    info)   return 0 ;;
    list)   printf 'RUNNING\n' ;;
    config) printf 'ssh\n' ;;
    exec)   cat >/dev/null ;;
    *)      return 0 ;;
  esac
}
export -f incus

export SUBYARD_CONFIG_DIR="$TMP/shipped-config"
export SUBYARD_NO_AUDIT=1
export SUBYARD_SECURITY_SKIP_LIVE=1
mkdir -p "$SUBYARD_HOME" "$SUBYARD_CONFIG_HOME" "$SUBYARD_CONFIG_DIR"
printf '1G %s\n' "$(date +%s)" > "$SUBYARD_HOME/space.cache"

output="$("$ROOT/bin/yard" status </dev/null)"
for expected in \
  'android   emulator' \
  'openclaw  qa-bot-broker' \
  'openclaw  staging-gateway'
do
  grep -Fq "$expected" <<<"$output" || {
    printf 'missing status row: %s\n\n%s\n' "$expected" "$output" >&2
    exit 1
  }
done
grep -Fq 'security static-only' <<<"$output" || {
  printf 'status did not distinguish static-only security checks:\n\n%s\n' "$output" >&2
  exit 1
}

printf 'ok: yard status keeps every active profile resource and labels static security\n'
