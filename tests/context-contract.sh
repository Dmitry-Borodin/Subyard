#!/usr/bin/env bash
# Pure context validation and bind-path policy checks.
# shellcheck disable=SC2034,SC2209 # assignments are consumed by sourced context helpers
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/context.sh
. "$ROOT/scripts/lib/context.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/host-data"

SUBYARD_OPERATOR_HOME="$tmp/home"
SUBYARD_CONFIG_HOME="$tmp/config"
SUBYARD_HOME="$tmp/data"
STORAGE_PATH="$SUBYARD_HOME/incus/storage"
HOST_BASE="$tmp/host-data"
RESTRICTED_DISK_PATHS="$HOST_BASE"
YARD_TYPE=local
INSTANCE_TYPE=container
SHIFT_MODE=shift
FORWARD_SSH_AGENT=0
DEV_SUDO=0
DEV_UID=1000
SSH_PORT=2222

context_validate || fail "$CONTEXT_ERROR"

NESTED_E2E_VMS=wat
! context_validate || fail "invalid nested VM opt-in accepted"
NESTED_E2E_VMS=1
INSTANCE_TYPE=vm
! context_validate || fail "nested E2E VMs accepted on an unsupported yard type"
INSTANCE_TYPE=container
context_validate || fail "valid nested E2E VM context rejected: $CONTEXT_ERROR"
E2E_VM_DISK=20GiB
! context_validate || fail "undersized nested E2E VM disk accepted"
E2E_VM_DISK=30GiB
NESTED_E2E_VMS=0
path_is_broad_host_root / || fail "root was not classified broad"
path_is_broad_host_root "$SUBYARD_OPERATOR_HOME" || fail "operator home was not classified broad"

SSH_PORT=70000
! context_validate || fail "invalid SSH_PORT accepted"
case "$CONTEXT_ERROR" in *SSH_PORT*) ;; *) fail "wrong invalid-port diagnostic: $CONTEXT_ERROR" ;; esac
SSH_PORT=2222

HOST_BASE=/
RESTRICTED_DISK_PATHS=/
! context_validate || fail "broad HOST_BASE accepted"

HOST_BASE="$tmp/host-data/../host-data"
RESTRICTED_DISK_PATHS="$tmp/host-data"
context_validate || fail "equivalent non-normalized paths were rejected: $CONTEXT_ERROR"
[ "$HOST_BASE" = "$tmp/host-data" ] || fail "HOST_BASE was not normalized"

printf 'ok: normalized context contract\n'
