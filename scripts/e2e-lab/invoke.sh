#!/usr/bin/env bash
# Physical L0-to-L1 worker invocation; Go owns validation and policy.
set -euo pipefail

[ "${SUBYARD_ENGINE_CONTEXT:-}" = 1 ] \
  || { printf 'test-vms: prepared engine context required\n' >&2; exit 2; }
WORKER=/usr/local/libexec/subyard/test-vms-inner
PROJ=(--project "${INCUS_PROJECT:?}")

incus exec "${INSTANCE_NAME:?}" "${PROJ[@]}" -- test -x "$WORKER" \
  || { printf 'test-vms: worker is not installed; run yard init\n' >&2; exit 1; }
exec incus exec "${INSTANCE_NAME:?}" "${PROJ[@]}" --mode=non-interactive -- "$WORKER" "$@"
