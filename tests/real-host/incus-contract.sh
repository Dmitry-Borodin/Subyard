#!/usr/bin/env bash
# Opt-in official-client contract against one dedicated container and one VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SUBYARD_REAL_INCUS_SOCKET:?set SUBYARD_REAL_INCUS_SOCKET}"
: "${SUBYARD_REAL_INCUS_CONTAINER_PROJECT:?set SUBYARD_REAL_INCUS_CONTAINER_PROJECT}"
: "${SUBYARD_REAL_INCUS_CONTAINER_INSTANCE:?set SUBYARD_REAL_INCUS_CONTAINER_INSTANCE}"
: "${SUBYARD_REAL_INCUS_VM_PROJECT:?set SUBYARD_REAL_INCUS_VM_PROJECT}"
: "${SUBYARD_REAL_INCUS_VM_INSTANCE:?set SUBYARD_REAL_INCUS_VM_INSTANCE}"
command -v go >/dev/null 2>&1 || { printf 'incus-contract: Go is required\n' >&2; exit 2; }

run_contract() { # type project instance
  SUBYARD_REAL_INCUS_SOCKET="$SUBYARD_REAL_INCUS_SOCKET" \
    SUBYARD_REAL_INCUS_PROJECT="$2" \
    SUBYARD_REAL_INCUS_INSTANCE="$3" \
    SUBYARD_REAL_INCUS_TYPE="$1" \
    go test -tags realincus ./internal/adapters/incusclient \
      -run '^TestRealIncusConformance$' -count=1
}

cd "$ROOT"
run_contract container "$SUBYARD_REAL_INCUS_CONTAINER_PROJECT" "$SUBYARD_REAL_INCUS_CONTAINER_INSTANCE"
run_contract vm "$SUBYARD_REAL_INCUS_VM_PROJECT" "$SUBYARD_REAL_INCUS_VM_INSTANCE"
printf 'ok: official Incus client contract passed for container and VM\n'
