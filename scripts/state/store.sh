#!/usr/bin/env bash
# store.sh — compatibility calls into the native atomic project-state service.

[ -n "${SUBYARD_STATE_STORE_SOURCED:-}" ] && return 0
SUBYARD_STATE_STORE_SOURCED=1

STATE_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_REPOSITORY_ROOT="${SUBYARD_REPOSITORY_ROOT:-$(cd "$STATE_MODULE_DIR/../.." && pwd)}"
STATE_DIR="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}"
STATE_SCHEMA=1

state_engine() {
  SUBYARD_NO_AUDIT=1 "$STATE_REPOSITORY_ROOT/bin/yard" _state "$@"
}

project_id()      { state_engine project-id "${1:?project_id needs a path}"; }
yard_path_for()   { state_engine yard-path "${1:?need id}"; }
ws_device_for()   { state_engine device "${1:?need id}"; }
state_file()      { printf '%s/%s.json\n' "$STATE_DIR" "${1:?need id}"; }

state_record_valid_file() {
  local file="${1:?need state file}" expected_id
  expected_id="${2:-$(basename "$file" .json)}"
  state_engine validate-file "$file" "$expected_id" >/dev/null 2>&1
}

state_require_valid() {
  local id="${1:?need id}"
  state_engine get "$id" projectId >/dev/null \
    || die "invalid project state '$(state_file "$id")' (expected schema $STATE_SCHEMA); repair or remove it"
}

state_write() {
  [ "$#" -eq 6 ] || die "internal: state_write needs six arguments"
  state_engine write "$@"
}

state_exists() { state_engine exists "${1:?need id}" >/dev/null 2>&1; }
state_remove() { state_engine remove "${1:?need id}"; }
state_get()    { state_engine get "${1:?need id}" "${2:?need field}"; }
state_set()    { state_engine set "${1:?need id}" "${2:?need field}" "${3-}"; }

state_project_id_valid() { state_engine valid id "${1:-}" >/dev/null 2>&1; }
state_project_mode_valid() { state_engine valid mode "${1:-}" >/dev/null 2>&1; }
state_project_target_valid() { state_engine valid target "${1:-}" >/dev/null 2>&1; }
state_yard_record_valid() {
  state_project_id_valid "$1" && state_project_mode_valid "$2" && state_project_target_valid "$3"
}

state_upsert_yard() {
  [ "$#" -eq 5 ] || die "internal: state_upsert_yard needs five arguments"
  state_engine upsert-yard "$@"
}

state_validate_all() { state_engine validate; }
state_ids() { state_engine ids; }
