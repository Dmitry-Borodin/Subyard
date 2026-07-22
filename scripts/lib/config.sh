#!/usr/bin/env bash
# config.sh — layered config loading with one explicit normalization/validation boundary.

[ -n "${SUBYARD_CONFIG_SOURCED:-}" ] && return 0
SUBYARD_CONFIG_SOURCED=1

SUBYARD_CONFIG_DIR="${SUBYARD_CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../config" 2>/dev/null && pwd)}"

load_config() {
  [ -n "${SUBYARD_CONFIG_LOADED:-}" ] && return 0
  SUBYARD_CONFIG_LOADED=1
  : "${SUBYARD_OPERATOR_HOME:=$(subyard_operator_home)}"
  # shellcheck disable=SC1091
  [ -r "$SUBYARD_CONFIG_DIR/../private/config.env" ] && . "$SUBYARD_CONFIG_DIR/../private/config.env"
  yard_context_select
  local file
  for file in incus.project.env subyard.env host.env agents.env ports.env; do
    # shellcheck disable=SC1090
    [ -r "$SUBYARD_CONFIG_DIR/$file" ] && . "$SUBYARD_CONFIG_DIR/$file"
  done
  return 0
}

subyard_context_load() {
  [ -n "${SUBYARD_CONTEXT_READY:-}" ] && return 0
  load_config
  context_validate || die "invalid Subyard context: $CONTEXT_ERROR"
  SUBYARD_CONTEXT_READY=1
}
