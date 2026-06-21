#!/usr/bin/env bash
# lib-state.sh — machine-local state + audit log for yard project commands.
# Source it (after lib.sh); do not execute. Pure host-side: no incus, no root.
#
# Two host locations (both operator-owned, overridable by env):
#   - config/state: $SUBYARD_CONFIG_HOME (default ~/.config/subyard)  → projects/<id>.json
#   - data/logs:    $SUBYARD_HOME         (default ~/.subyard)         → logs/yard.log
# These match existing code (01-install-incus.sh uses ~/.subyard) and the spec's
# ~/.config/subyard for portable machine-local state.

[ -n "${SUBYARD_LIBSTATE_SOURCED:-}" ] && return 0
SUBYARD_LIBSTATE_SOURCED=1

command -v jq >/dev/null 2>&1 || die "jq not found on host (needed for project state) — apt-get install jq"

SUBYARD_CONFIG_HOME="${SUBYARD_CONFIG_HOME:-$HOME/.config/subyard}"
SUBYARD_HOME="${SUBYARD_HOME:-$HOME/.subyard}"
STATE_DIR="$SUBYARD_CONFIG_HOME/projects"
LOG_DIR="$SUBYARD_HOME/logs"
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
# Same id → same name, so import attaches and remove detaches the same device.
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

# audit <command> [args...] — append one host-side invocation record. Best-effort:
# never fails the caller (logging must not break the CLI).
audit() {
  install -d -m 700 "$LOG_DIR" 2>/dev/null || return 0
  printf '%s pid=%s cwd=%s -- %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$PWD" "$*" \
    >>"$LOG_DIR/yard.log" 2>/dev/null || true
}
