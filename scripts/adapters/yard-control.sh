#!/usr/bin/env bash
# Structured lifecycle adapter. The Go engine validates the context, owns confirmation and sends
# the metadata envelope on fd 3; this wrapper keeps the existing guarded Bash side-effect path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

[ "${SUBYARD_ADAPTER_SCHEMA:-}" = 1 ] || {
  printf 'yard-control adapter requires schema 1\n' >&2
  exit 2
}
[ "${SUBYARD_METADATA_FD:-}" = 3 ] || {
  printf 'yard-control adapter requires metadata fd 3\n' >&2
  exit 2
}
case "${SUBYARD_OPERATION_ID:-}" in
  '' | -* | *[!A-Za-z0-9._-]*)
    printf 'yard-control adapter received an invalid operation ID\n' >&2
    exit 2
    ;;
esac

action="${1:-}"
case "$action" in
  start)
    # stdout is reserved for the one machine result. Human progress and diagnostics remain on the
    # adapter diagnostics channel captured by the structured runner.
    "$ROOT/scripts/yard-ctl.sh" start --yes >&2
    printf '{"schema":1,"operationId":"%s","status":"ok","output":{"action":"start"}}\n' \
      "$SUBYARD_OPERATION_ID"
    ;;
  *)
    printf 'yard-control adapter does not allow action %s\n' "${action:-<empty>}" >&2
    exit 2
    ;;
esac
