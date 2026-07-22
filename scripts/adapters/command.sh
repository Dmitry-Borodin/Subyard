#!/usr/bin/env bash
# Structured bridge from a Go-owned operation to an allowlisted physical command handler.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

[ "${SUBYARD_ADAPTER_SCHEMA:-}" = 1 ] || { printf 'command adapter requires schema 1\n' >&2; exit 2; }
[ "${SUBYARD_METADATA_FD:-}" = 3 ] || { printf 'command adapter requires metadata fd 3\n' >&2; exit 2; }
case "${SUBYARD_OPERATION_ID:-}" in
  '' | -* | *[!A-Za-z0-9._-]*) printf 'command adapter received an invalid operation ID\n' >&2; exit 2 ;;
esac

action="${1:-}"; shift || true
case "$action" in
  init)       handler="$ROOT/scripts/init.sh" ;;
  keys)       handler="$ROOT/scripts/yard-keys.sh" ;;
  shell)      handler="$ROOT/scripts/yard-shell.sh" ;;
  provision)  handler="$ROOT/scripts/10-provision-profile.sh" ;;
  test-vms)   handler="$ROOT/scripts/test-vms.sh" ;;
  stop)       handler="$ROOT/scripts/yard-ctl.sh" ;;
  teardown)   handler="$ROOT/scripts/99-teardown.sh" ;;
  sync|bind)  handler="$ROOT/scripts/project-sync.sh" ;;
  clone)      handler="$ROOT/scripts/project-clone.sh" ;;
  code)       handler="$ROOT/scripts/project-code.sh" ;;
  export)     handler="$ROOT/scripts/project-export.sh" ;;
  remove)     handler="$ROOT/scripts/project-remove.sh" ;;
  up|down)    handler="$ROOT/scripts/project-env.sh" ;;
  remote)     handler="$ROOT/scripts/yard-remote.sh" ;;
  update)     handler="$ROOT/scripts/update-engine.sh" ;;
  *) printf 'command adapter does not allow action %s\n' "${action:-<empty>}" >&2; exit 2 ;;
esac

"$handler" "$@" >&2
printf '{"schema":1,"operationId":"%s","status":"ok","output":{"command":"%s"}}\n' \
  "$SUBYARD_OPERATION_ID" "$action"
