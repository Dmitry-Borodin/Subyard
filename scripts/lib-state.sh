#!/usr/bin/env bash
# lib-state.sh — machine-local project state for yard project commands.
# Source it (after lib.sh); do not execute. Pure host-side: no incus, no root.
#
# State location (operator-owned, overridable by env):
#   - config/state: $SUBYARD_CONFIG_HOME (default ~/.config/subyard)  → projects/<id>.json
# matching the spec's ~/.config/subyard for portable machine-local state. The audit log
# ($SUBYARD_HOME/logs/yard.log) is written SOLELY by the dispatcher (bin/yard); this file
# does not log.

[ -n "${SUBYARD_LIBSTATE_SOURCED:-}" ] && return 0
SUBYARD_LIBSTATE_SOURCED=1

command -v jq >/dev/null 2>&1 || die "jq not found on host (needed for project state) — apt-get install jq"

# SUBYARD_CONFIG_HOME comes from config/host.env, already loaded by lib.sh (sourced before
# this file) — the single place host paths are named.
STATE_DIR="$SUBYARD_CONFIG_HOME/projects"
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

# state_write <id> <name> <hostPath> <yardPath> <mode> <sshHost>
state_write() {
  local id="$1" name="$2" hostPath="$3" yardPath="$4" mode="$5" sshHost="$6"
  install -d -m 700 "$STATE_DIR"
  local f; f="$(state_file "$id")"
  jq -n \
    --argjson schema "$STATE_SCHEMA" \
    --arg projectId "$id" --arg name "$name" \
    --arg hostPath "$hostPath" --arg yardPath "$yardPath" \
    --arg mode "$mode" --arg sshHost "$sshHost" \
    --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:$schema, projectId:$projectId, name:$name, hostPath:$hostPath,
      yardPath:$yardPath, mode:$mode, sshHost:$sshHost, importedAt:$importedAt}' \
    >"$f.tmp" && mv -f "$f.tmp" "$f"
}

state_exists() { [ -f "$(state_file "$1")" ]; }
state_remove() { rm -f "$(state_file "$1")"; }
state_get()    { jq -r --arg k "$2" '.[$k] // ""' "$(state_file "$1")"; }
# state_set <id> <key> <value> — merge one string field into an existing record.
state_set() {
  local f; f="$(state_file "$1")"; [ -f "$f" ] || return 1
  jq --arg k "$2" --arg v "$3" '.[$k]=$v' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}
# List ids of all known projects (empty output if none).
state_ids() {
  [ -d "$STATE_DIR" ] || return 0
  local f
  for f in "$STATE_DIR"/*.json; do [ -e "$f" ] && basename "$f" .json; done
}

# resolve_project_id <arg> — map a CLI argument to a known project id, so commands
# can take a project by NAME from `yard list` (no need to be in its folder). Accepts:
# a registered path (incl. the default '.'), an exact id, or a project name
# (case-insensitive, must be unique). Prints the id; dies with a helpful message.
resolve_project_id() {
  local arg="${1:-.}" id nm; local -a matches=()
  if [ -e "$arg" ]; then
    id="$(project_id "$arg")"
    state_exists "$id" && { printf '%s\n' "$id"; return 0; }
  fi
  state_exists "$arg" && { printf '%s\n' "$arg"; return 0; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    nm="$(state_get "$id" name)"
    [ "${nm,,}" = "${arg,,}" ] && matches+=("$id")
  done < <(state_ids)
  [ "${#matches[@]}" -eq 1 ] && { printf '%s\n' "${matches[0]}"; return 0; }
  [ "${#matches[@]}" -gt 1 ] && die "'$arg' matches multiple projects — use a path or the exact id (see: ${PROG:-yard} list)"
  [ -e "$arg" ] && die "'$(basename "$(realpath "$arg")")' is not in the yard — run: ${PROG:-yard} sync $arg (or: bind $arg)"
  die "no project '$arg' in the yard — see: ${PROG:-yard} list"
}
