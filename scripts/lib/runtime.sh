#!/usr/bin/env bash
# runtime.sh — invocation identity shared by source-only Subyard modules.
# shellcheck disable=SC2034 # caller path/argv are consumed by resolver re-exec entrypoints.

[ -n "${SUBYARD_RUNTIME_SOURCED:-}" ] && return 0
SUBYARD_RUNTIME_SOURCED=1

SUBYARD_SCRIPT_PATH="$0"
SUBYARD_SCRIPT_ARGV=("$@")

subyard_operator_home() {
  local user="${SUBYARD_USER:-${SUDO_USER:-${USER:-}}}" home=
  if [ -n "$user" ]; then home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"; fi
  printf '%s\n' "${home:-$HOME}"
}
