#!/usr/bin/env bash
# Host-free security-lint contract, including malicious profile mounts.
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
export SUBYARD_SECURITY_SKIP_LIVE=1
mkdir -p "$TMP/home" "$TMP/profiles/safe" "$TMP/profiles/bad"
: > "$TMP/profiles/safe/profile.conf"

bash "$ROOT/scripts/security-lint.sh" --quiet

printf '%s\n' 'ENV_MOUNTS="/var/run/docker.sock:/var/run/docker.sock"' \
  > "$TMP/profiles/bad/profile.conf"
if bash "$ROOT/scripts/security-lint.sh" --quiet >"$TMP/bad.out" 2>&1; then
  fail "docker socket profile passed security lint"
fi
grep -Fq 'host-control socket' "$TMP/bad.out" || fail "socket failure is unclear"
: > "$TMP/profiles/bad/profile.conf"

# Live lint inspects the expanded device set, including inherited profile devices.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/incus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'info ' | 'info yard') exit 0 ;;
  'project show') exit 0 ;;
  'project get')
    case "${4:-}" in
      restricted) printf 'true\n' ;;
      restricted.containers.privilege) printf 'unprivileged\n' ;;
    esac ;;
  'config get') printf 'false\n' ;;
  'config device')
    case "${3:-}" in
      list) printf '%s\n' "${MOCK_DEVICE_NAME:-fixture}" ;;
      get)
        case "${6:-}" in
          type) printf '%s\n' "${MOCK_DEVICE_TYPE:-disk}" ;;
          source) printf '%s\n' "${MOCK_DEVICE_SOURCE:-}" ;;
          path) printf '%s\n' "${MOCK_DEVICE_PATH:-/workspace}" ;;
          listen) printf '%s\n' "${MOCK_DEVICE_LISTEN:-}" ;;
        esac ;;
    esac ;;
esac
SH
chmod +x "$TMP/bin/incus"
PATH="$TMP/bin:$PATH" SUBYARD_SECURITY_SKIP_LIVE=0 MOCK_DEVICE_SOURCE="$TMP/projects/demo" \
  bash "$ROOT/scripts/security-lint.sh" --quiet --require-live
PATH="$TMP/bin:$PATH" SUBYARD_SECURITY_SKIP_LIVE=0 MOCK_DEVICE_SOURCE=/etc \
  bash "$ROOT/scripts/security-lint.sh" --require-live >"$TMP/live-explicit.out" 2>&1
grep -Fq 'encapsulation is reduced' "$TMP/live-explicit.out" || fail "explicit bind warning is unclear"
if PATH="$TMP/bin:$PATH" SUBYARD_SECURITY_SKIP_LIVE=0 \
  MOCK_DEVICE_NAME=host-fixture MOCK_DEVICE_SOURCE=/etc \
  bash "$ROOT/scripts/security-lint.sh" --quiet --require-live >"$TMP/live-bad.out" 2>&1; then
  fail "managed disk outside HOST_BASE passed security lint"
fi
grep -Fq 'managed disk device' "$TMP/live-bad.out" || fail "managed disk failure is unclear"
if PATH="$TMP/bin:$PATH" SUBYARD_SECURITY_SKIP_LIVE=0 \
  MOCK_DEVICE_TYPE=unix-char MOCK_DEVICE_SOURCE=/dev/mem \
  bash "$ROOT/scripts/security-lint.sh" --quiet --require-live >"$TMP/char-bad.out" 2>&1; then
  fail "unsupported unix-char device passed security lint"
fi
grep -Fq 'supported device allowlist' "$TMP/char-bad.out" || fail "unix-char failure is unclear"

printf 'ok: security lint rejects unsafe static and expanded live devices\n'
