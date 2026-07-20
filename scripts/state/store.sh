#!/usr/bin/env bash
# store.sh — atomic machine-local project records and schema validation.

[ -n "${SUBYARD_STATE_STORE_SOURCED:-}" ] && return 0
SUBYARD_STATE_STORE_SOURCED=1

command -v jq >/dev/null 2>&1 || die "jq not found on host (needed for project state) — apt-get install jq"

# SUBYARD_CONFIG_HOME comes from the explicitly loaded context; config/host.env is the single
# place host paths are named.
STATE_DIR="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}"
STATE_SCHEMA=1

# Stable, machine-local id: <sanitized-basename>-<sha256(realpath)[:8]>.
# Same host path → same id; the in-yard path /srv/workspaces/<id>/src is derived from it.
project_id() {
  local p hp base hash
  p="${1:?project_id needs a path}"
  hp="$(realpath -- "$p")" || die "no such path: $p"
  base="$(basename -- "$hp")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  hash="$(printf '%s' "$hp" | sha256sum | cut -c1-8)"
  printf '%s-%s\n' "$base" "$hash"
}

yard_path_for()  { printf '/srv/workspaces/%s/src\n' "${1:?need id}"; }
state_file()     { printf '%s/%s.json\n' "$STATE_DIR" "${1:?need id}"; }
# Deterministic Incus disk-device name for a bind project (valid device chars only).
# Same id → same name, so bind attaches and remove detaches the same device.
ws_device_for()  { printf 'ws-%s\n' "$(printf '%s' "${1:?need id}" | tr -c 'A-Za-z0-9' '-')"; }

# state_record_valid_file <file> [expected-id] — schema-1 compatibility boundary. Optional fields
# may be added without a migration, but the identity and fields consumed by project commands remain
# typed. A different schema is never read accidentally; it needs an explicit migration first.
state_record_valid_file() {
  local file="${1:?need state file}" expected_id="${2:-}" id mode target
  jq -e '
    type == "object" and
    .schema == 1 and
    (.projectId | type == "string") and
    (.name | type == "string") and
    (.hostPath | type == "string") and
    (.yardPath | type == "string") and
    (.mode | type == "string") and
    (.sshHost | type == "string") and
    ((.importedAt == null) or (.importedAt | type == "string")) and
    ((.target == null) or (.target | type == "string")) and
    ((.profile == null) or (.profile | type == "string")) and
    ((.registrySource == null) or .registrySource == "yard")
  ' "$file" >/dev/null 2>&1 || return 1
  id="$(jq -r '.projectId' "$file")"
  mode="$(jq -r '.mode' "$file")"
  target="$(jq -r '.target // ""' "$file")"
  state_project_id_valid "$id" && state_project_mode_valid "$mode" \
    && state_project_target_valid "$target" || return 1
  [ -z "$expected_id" ] || [ "$id" = "$expected_id" ]
}

state_require_valid() {
  local id="${1:?need id}" file
  state_project_id_valid "$id" || die "invalid project state id '$id'"
  file="$(state_file "$id")"
  [ -f "$file" ] || die "project state '$id' does not exist"
  state_record_valid_file "$file" "$id" \
    || die "invalid project state '$file' (expected schema $STATE_SCHEMA); repair or remove it"
}

# _state_replace <file> <candidate> — validate and atomically publish an already-written record.
_state_replace() {
  local file="${1:?need destination}" candidate="${2:?need candidate}" expected_id
  expected_id="$(basename "$file" .json)"
  if ! state_record_valid_file "$candidate" "$expected_id"; then
    rm -f -- "$candidate"
    return 1
  fi
  chmod 600 "$candidate" || { rm -f -- "$candidate"; return 1; }
  mv -f -- "$candidate" "$file"
}

# state_write <id> <name> <hostPath> <yardPath> <mode> <sshHost>
state_write() {
  local id="$1" name="$2" hostPath="$3" yardPath="$4" mode="$5" sshHost="$6" f tmp
  state_project_id_valid "$id" || die "invalid project state id '$id'"
  state_project_mode_valid "$mode" || die "invalid project mode '$mode'"
  install -d -m 700 "$STATE_DIR"
  f="$(state_file "$id")"
  tmp="$(mktemp "$STATE_DIR/.${id}.json.tmp.XXXXXX")" || return 1
  if ! jq -n \
    --argjson schema "$STATE_SCHEMA" \
    --arg projectId "$id" --arg name "$name" \
    --arg hostPath "$hostPath" --arg yardPath "$yardPath" \
    --arg mode "$mode" --arg sshHost "$sshHost" \
    --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:$schema, projectId:$projectId, name:$name, hostPath:$hostPath,
      yardPath:$yardPath, mode:$mode, sshHost:$sshHost, importedAt:$importedAt}' \
    >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  _state_replace "$f" "$tmp"
}

state_exists() {
  local id="${1:?need id}" file
  state_project_id_valid "$id" || return 1
  file="$(state_file "$id")"
  [ -f "$file" ] || return 1
  state_require_valid "$id"
}
state_remove() {
  state_project_id_valid "${1:-}" || die "invalid project state id '${1:-}'"
  rm -f -- "$(state_file "$1")"
}
state_get() {
  state_require_valid "$1"
  jq -r --arg k "$2" '.[$k] // ""' "$(state_file "$1")"
}
# state_set <id> <key> <value> — merge one string field into an existing record.
state_set() {
  local id="$1" key="$2" value="$3" f tmp
  case "$key" in
    target) state_project_target_valid "$value" || die "invalid project target '$value'" ;;
    profile) [ -z "$value" ] || yard_valid_name "$value" || die "invalid project profile '$value'" ;;
    registrySource) [ "$value" = yard ] || die "invalid project registry source '$value'" ;;
    *) die "unsupported project state field '$key'" ;;
  esac
  state_require_valid "$id"
  f="$(state_file "$id")"
  tmp="$(mktemp "$STATE_DIR/.${id}.json.tmp.XXXXXX")" || return 1
  if ! jq --arg k "$key" --arg v "$value" '.[$k]=$v' "$f" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  _state_replace "$f" "$tmp"
}

# Yard metadata is dev-owned and therefore untrusted at the host boundary. These validators guard
# every metadata-driven state write: projectId becomes a filename, and target later selects a
# profile path. Never let either carry path syntax back onto the owner/controller host.
state_project_id_valid() {
  case "${1:-}" in '' | -* | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

state_project_mode_valid() { case "${1:-}" in sync | git | bind) return 0 ;; *) return 1 ;; esac; }

state_project_target_valid() {
  [ -z "${1:-}" ] || [ "$1" = yard ] || yard_valid_name "$1"
}

state_yard_record_valid() {
  state_project_id_valid "$1" && state_project_mode_valid "$2" && state_project_target_valid "$3"
}

# state_upsert_yard <id> <name> <mode> <target-or-empty> <ssh-host> — converge facts learned
# from the yard while preserving controller-specific state. In particular, never import another
# controller's hostPath and never erase a real owner-local one. Existing timestamps stay stable;
# a new synthetic record is explicitly marked so its empty path renders as `(yard)`.
state_upsert_yard() {
  local id="$1" name="$2" mode="$3" target="$4" ssh_host="$5" f tmp
  state_yard_record_valid "$id" "$mode" "$target" || return 1
  f="$(state_file "$id")"
  if [ ! -f "$f" ]; then
    state_write "$id" "$name" "" "$(yard_path_for "$id")" "$mode" "$ssh_host"
    [ -z "$target" ] || state_set "$id" target "$target"
    state_set "$id" registrySource yard
    return 0
  fi
  state_require_valid "$id"
  tmp="$(mktemp "$STATE_DIR/.${id}.json.tmp.XXXXXX")" || return 1
  if ! jq --arg name "$name" --arg mode "$mode" --arg target "$target" \
     --arg yardPath "$(yard_path_for "$id")" --arg sshHost "$ssh_host" '
      .name=$name | .mode=$mode | .yardPath=$yardPath | .sshHost=$sshHost |
      if $target != "" then .target=$target else . end |
      if (.hostPath // "") == "" then .registrySource="yard" else del(.registrySource) end
    ' "$f" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  _state_replace "$f" "$tmp"
}
# List ids of all known projects (empty output if none).
state_validate_all() {
  [ -d "$STATE_DIR" ] || return 0
  local file id
  for file in "$STATE_DIR"/*.json; do
    [ -e "$file" ] || continue
    id="$(basename "$file" .json)"
    state_record_valid_file "$file" "$id" \
      || { printf 'invalid project state %s (expected schema %s); repair or remove it\n' \
        "$file" "$STATE_SCHEMA" >&2; return 1; }
  done
}

state_ids() {
  [ -d "$STATE_DIR" ] || return 0
  local f id
  for f in "$STATE_DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    printf '%s\n' "$id"
  done
}
