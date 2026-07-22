#!/usr/bin/env bash
# Opt-in official-client contract against one dedicated container and one VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SUBYARD_REAL_INCUS_SOCKET:?set SUBYARD_REAL_INCUS_SOCKET}"
: "${SUBYARD_REAL_INCUS_CONTAINER_PROJECT:?set SUBYARD_REAL_INCUS_CONTAINER_PROJECT}"
: "${SUBYARD_REAL_INCUS_CONTAINER_INSTANCE:?set SUBYARD_REAL_INCUS_CONTAINER_INSTANCE}"
: "${SUBYARD_REAL_INCUS_VM_PROJECT:?set SUBYARD_REAL_INCUS_VM_PROJECT}"
: "${SUBYARD_REAL_INCUS_VM_INSTANCE:?set SUBYARD_REAL_INCUS_VM_INSTANCE}"
TEST_BINARY="${SUBYARD_REAL_INCUS_TEST_BINARY:-}"
if [ -n "$TEST_BINARY" ]; then
  case "$TEST_BINARY" in /*) ;; *) printf 'incus-contract: test binary must be absolute\n' >&2; exit 2 ;; esac
  [ -x "$TEST_BINARY" ] || { printf 'incus-contract: test binary is not executable\n' >&2; exit 2; }
else
  command -v go >/dev/null 2>&1 || { printf 'incus-contract: Go is required\n' >&2; exit 2; }
fi

run_contract() { # type project instance
  if [ -n "$TEST_BINARY" ]; then
    SUBYARD_REAL_INCUS_SOCKET="$SUBYARD_REAL_INCUS_SOCKET" \
      SUBYARD_REAL_INCUS_PROJECT="$2" \
      SUBYARD_REAL_INCUS_INSTANCE="$3" \
      SUBYARD_REAL_INCUS_TYPE="$1" \
      "$TEST_BINARY" -test.run '^TestRealIncusConformance$' -test.count=1
  else
    SUBYARD_REAL_INCUS_SOCKET="$SUBYARD_REAL_INCUS_SOCKET" \
      SUBYARD_REAL_INCUS_PROJECT="$2" \
      SUBYARD_REAL_INCUS_INSTANCE="$3" \
      SUBYARD_REAL_INCUS_TYPE="$1" \
      go test -tags realincus ./internal/adapters/incusclient \
        -run '^TestRealIncusConformance$' -count=1
  fi
}

cd "$ROOT"
run_contract container "$SUBYARD_REAL_INCUS_CONTAINER_PROJECT" "$SUBYARD_REAL_INCUS_CONTAINER_INSTANCE"
run_contract vm "$SUBYARD_REAL_INCUS_VM_PROJECT" "$SUBYARD_REAL_INCUS_VM_INSTANCE"
printf 'ok: official Incus client contract passed for container and VM\n'
