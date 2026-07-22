#!/usr/bin/env bash
# `yard bind` accepts arbitrary explicit host paths and warns before Incus access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/home/.ssh" "$TMP/arbitrary/project" "$TMP/bin"
cat > "$TMP/bin/incus" <<'SH'
#!/usr/bin/env bash
printf 'incus was called: %s\n' "$*" >> "$MOCK_INCUS_LOG"
exit 99
SH
chmod +x "$TMP/bin/incus"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SUBYARD_NO_AUDIT=1
export MOCK_INCUS_LOG="$TMP/incus.log"

check_explicit_path() {
  local path="$1" label="$2"
  : > "$MOCK_INCUS_LOG"
  if SUBYARD_PROJECT_SNAPSHOT=1 SUBYARD_PROJECT_ID="project-12345678" \
    SUBYARD_PROJECT_NAME="project" SUBYARD_PROJECT_HOST_PATH="$path" \
    SUBYARD_PROJECT_YARD_PATH="/srv/workspaces/project-12345678/src" \
    SUBYARD_PROJECT_MODE=bind SUBYARD_PROJECT_SSH_HOST=yard SUBYARD_PROJECT_TARGET=yard \
    SUBYARD_PROJECT_DEVICE=ws-project-12345678 SUBYARD_PROJECT_EXISTS=0 \
    "$ROOT/scripts/project-sync.sh" bind --yes >"$TMP/$label.out" 2>&1; then
    fail "mocked bind unexpectedly completed: $label"
  fi
  grep -Fq 'explicit bind exposes the host path directly to the yard' "$TMP/$label.out" \
    || fail "encapsulation warning missing: $label"
  if [ ! -s "$MOCK_INCUS_LOG" ]; then
    sed 's/^/  | /' "$TMP/$label.out" >&2
    fail "explicit path was rejected before Incus: $label"
  fi
}

check_explicit_path "$TMP/arbitrary/project" arbitrary
check_explicit_path "$TMP/home/.ssh" credential-directory

printf 'ok: yard bind accepts arbitrary explicit paths with an encapsulation warning\n'
