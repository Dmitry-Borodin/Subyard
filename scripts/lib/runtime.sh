#!/usr/bin/env bash
# runtime.sh — invocation identity shared by source-only Subyard modules.
# shellcheck disable=SC2034 # caller path/argv are consumed by resolver re-exec entrypoints.

[ -n "${SUBYARD_RUNTIME_SOURCED:-}" ] && return 0
SUBYARD_RUNTIME_SOURCED=1

if [ -n "${SUBYARD_DISPATCH_PATH:-}" ] && [ -n "${SUBYARD_DISPATCH_COMMAND:-}" ]; then
  SUBYARD_SCRIPT_PATH="$SUBYARD_DISPATCH_PATH"
  SUBYARD_SCRIPT_ARGV=("$SUBYARD_DISPATCH_COMMAND")
  if [ -n "${SUBYARD_DISPATCH_ARG0:-}" ] && [ "${1:-}" = "$SUBYARD_DISPATCH_ARG0" ]; then
    SUBYARD_SCRIPT_ARGV+=("${@:2}")
  else
    SUBYARD_SCRIPT_ARGV+=("$@")
  fi
else
  SUBYARD_SCRIPT_PATH="$0"
  SUBYARD_SCRIPT_ARGV=("$@")
fi

subyard_operator_home() {
  local user="${SUBYARD_USER:-${SUDO_USER:-${USER:-}}}" home=
  if [ -n "$user" ]; then home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"; fi
  printf '%s\n' "${home:-$HOME}"
}
