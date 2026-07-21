#!/usr/bin/env bash
# resolver.sh — compatibility routing around the native cross-yard resolver.
# shellcheck disable=SC2034 # RESOLVED_ID is an intentional caller-visible out-parameter.

[ -n "${SUBYARD_STATE_RESOLVER_SOURCED:-}" ] && return 0
SUBYARD_STATE_RESOLVER_SOURCED=1

project_arg_in_context() {
  local arg="${1:-.}" here="${YARD_NAME:-default}" pfx rest
  if [ ! -e "$arg" ]; then
    case "$arg" in
      */*)
        pfx="${arg%%/*}"; rest="${arg#*/}"
        [ "$pfx" = "$here" ] && [ -n "$rest" ] && { printf '%s\n' "$rest"; return 0; }
        ;;
    esac
  fi
  printf '%s\n' "$arg"
}

resolve_project_id() { state_engine resolve-local "${1:-.}"; }
resolve_project_global() { state_engine resolve-global "${1:-.}"; }

reexec_in_yard() {
  local name="${1:?reexec_in_yard needs a yard}"
  [ -n "${SUBYARD_YARD_EXPLICIT:-}" ] && return 0
  exec env SUBYARD_YARD="$name" SUBYARD_YARD_EXPLICIT=1 \
    "$SUBYARD_SCRIPT_PATH" ${SUBYARD_SCRIPT_ARGV[@]+"${SUBYARD_SCRIPT_ARGV[@]}"}
}

resolve_project_ctx() {
  local arg="${1:-.}" line yard id
  if [ -n "${SUBYARD_YARD_EXPLICIT:-}" ]; then
    arg="$(project_arg_in_context "$arg")"
    RESOLVED_ID="$(resolve_project_id "$arg")"
    return 0
  fi
  line="$(resolve_project_global "$arg")"
  yard="${line%%$'\t'*}"; id="${line#*$'\t'}"
  [ "$yard" = "${YARD_NAME:-default}" ] || reexec_in_yard "$yard"
  RESOLVED_ID="$id"
}

route_sync_target() {
  local id="$1" at="$2" here="${YARD_NAME:-default}" target
  target="$(state_engine route-sync "$id" "$at")"
  [ "$target" = "$here" ] || reexec_in_yard "$target"
}
