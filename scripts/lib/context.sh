#!/usr/bin/env bash
# context.sh — normalization and validation for an explicitly loaded Subyard context.
# shellcheck disable=SC2034 # immutable context values are consumed through context_value.

[ -n "${SUBYARD_CONTEXT_SOURCED:-}" ] && return 0
SUBYARD_CONTEXT_SOURCED=1

# shellcheck disable=SC2034 # out-parameter consumed by config.sh and direct contract tests
CONTEXT_ERROR=""
declare -A SUBYARD_CONTEXT_VALUES=()
context_fail() { CONTEXT_ERROR="$*"; return 1; }

path_is_within() { local path="$1" root="$2"; [ "$path" = "$root" ] || [[ "$path" == "$root"/* ]]; }

path_is_broad_host_root() {
  local path="$1" operator_home="${SUBYARD_OPERATOR_HOME:-${HOME:-}}"
  case "$path" in / | /boot | /dev | /etc | /home | /opt | /proc | /root | /run | /srv | /sys | /usr | /var) return 0 ;; esac
  [ -n "$operator_home" ] && [ "$path" = "$operator_home" ]
}

context_normalize() {
  local key value
  for key in SUBYARD_OPERATOR_HOME SUBYARD_CONFIG_HOME SUBYARD_HOME STORAGE_PATH HOST_BASE RESTRICTED_DISK_PATHS; do
    value="${!key:-}"
    case "$value" in /*) printf -v "$key" '%s' "$(realpath -m -- "$value")" ;; esac
  done
}

context_validate() {
  # shellcheck disable=SC2034 # reset out-parameter
  CONTEXT_ERROR=""
  context_normalize
  case "${YARD_TYPE:-local}" in local | remote) ;; *) context_fail "YARD_TYPE must be local or remote"; return ;; esac
  case "${INSTANCE_TYPE:-container}" in container | vm) ;; *) context_fail "INSTANCE_TYPE must be container or vm"; return ;; esac
  case "${SHIFT_MODE:-shift}" in shift | acl) ;; *) context_fail "SHIFT_MODE must be shift or acl"; return ;; esac
  case "${FORWARD_SSH_AGENT:-0}" in 0 | 1) ;; *) context_fail "FORWARD_SSH_AGENT must be 0 or 1"; return ;; esac
  case "${DEV_SUDO:-0}" in 0 | 1) ;; *) context_fail "DEV_SUDO must be 0 or 1"; return ;; esac
  [[ "${DEV_UID:-}" =~ ^[0-9]+$ ]] || { context_fail "DEV_UID must be numeric"; return; }

  local key value
  for key in SUBYARD_OPERATOR_HOME SUBYARD_CONFIG_HOME SUBYARD_HOME STORAGE_PATH HOST_BASE RESTRICTED_DISK_PATHS; do
    value="${!key:-}"
    case "$value" in /*) ;; *) context_fail "$key must be an absolute path"; return ;; esac
  done
  [ "$HOST_BASE" = "$RESTRICTED_DISK_PATHS" ] \
    || { context_fail "HOST_BASE must equal RESTRICTED_DISK_PATHS (one host-mount boundary)"; return; }
  path_is_broad_host_root "$HOST_BASE" && { context_fail "HOST_BASE is too broad: $HOST_BASE"; return; }

  if [ "${YARD_TYPE:-local}" = local ]; then
    [[ "${SSH_PORT:-}" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] \
      || { context_fail "SSH_PORT must be an integer from 1 to 65535"; return; }
  else
    [ -n "${REMOTE_DEST:-}" ] || { context_fail "remote yard context requires REMOTE_DEST"; return; }
  fi
}

# Capture the normalized, non-secret command context behind a read-only accessor. Compatibility
# handlers still receive the original variables, but domain boundaries can consume this immutable
# input without re-reading config or ambient environment.
context_capture() {
  SUBYARD_CONTEXT_VALUES=(
    [yardName]="${YARD_NAME:-default}"
    [yardType]="${YARD_TYPE:-local}"
    [instanceType]="${INSTANCE_TYPE:-container}"
    [instanceName]="${INSTANCE_NAME:-yard}"
    [incusProject]="${INCUS_PROJECT:-subyard}"
    [sshHost]="${SSH_HOST:-yard}"
    [sshPort]="${SSH_PORT:-}"
    [remoteDest]="${REMOTE_DEST:-}"
    [remoteYard]="${REMOTE_YARD:-}"
    [configHome]="$SUBYARD_CONFIG_HOME"
    [dataHome]="$SUBYARD_HOME"
    [storagePath]="$STORAGE_PATH"
    [hostBase]="$HOST_BASE"
    [devUid]="$DEV_UID"
  )
  readonly -A SUBYARD_CONTEXT_VALUES
}

context_value() {
  local key="${1:?context_value needs a key}"
  [ -n "${SUBYARD_CONTEXT_VALUES[$key]+set}" ] || return 1
  printf '%s\n' "${SUBYARD_CONTEXT_VALUES[$key]}"
}
