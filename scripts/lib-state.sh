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

# --- cross-yard project addressing (multi-yard) ------------------------------
# All incus-free (read only machine-local state dirs). `resolve_project_id` above stays the
# in-context resolver. The helpers here add the "no explicit context" case: a project command
# with no -Y/@ figures out WHICH yard owns the argument and re-execs itself there. Global
# resolution applies ONLY when $SUBYARD_YARD_EXPLICIT is empty.

# state_dir_for_yard <name> — machine-local project state dir for ANY yard. Defined in lib.sh
# (always sourced before lib-state.sh, so it is in scope here).

# _state_field <dir> <id> <key> — read one string field from a state file in an arbitrary
# yard's state dir (missing file/key → empty). The cross-yard analogue of state_get, which
# is pinned to the loaded context's $STATE_DIR.
_state_field() { jq -r --arg k "$3" '.[$k] // ""' "$1/$2.json" 2>/dev/null || true; }

# _candidates_die <arg> <yard\tid>… — die on an ambiguous match, listing every candidate in
# the exact copy-pasteable form `yard/name  hostPath  importedAt`, then the disambiguation
# hint. The printed `yard/name` is precisely what a project command accepts (qualified name).
_candidates_die() {
  local arg="$1"; shift
  local c yard id d nm hp imp lines=""
  for c in "$@"; do
    yard="${c%%$'\t'*}"; id="${c#*$'\t'}"
    d="$(state_dir_for_yard "$yard")"
    nm="$(_state_field "$d" "$id" name)"; nm="${nm:-$id}"
    hp="$(_state_field "$d" "$id" hostPath)"
    imp="$(_state_field "$d" "$id" importedAt)"
    lines+="$(printf '  %s/%s  %s  %s' "$yard" "$nm" "$hp" "$imp")"$'\n'
  done
  die "$(printf "'%s' matches projects in multiple yards:\n%suse '<yard>/<name>' or -Y <yard>" "$arg" "$lines")"
}

# resolve_project_global <arg> — map a CLI argument to the OWNING yard + project id across ALL
# registry yards, printing "<yard>\t<id>". Precedence (first with a hit wins):
#   1. an existing path on disk → its realpath-derived id, searched across every yard;
#   2. an exact project id across yards;
#   3. a project name (case-insensitive) across yards;
#   4. a qualified `<yard>/<rest>` — ONLY when $arg is not an existing path and the prefix is a
#      registry name; <rest> resolves (id, then unique name) within that yard's state.
# 0 hits → a friendly die; >1 hits at any stage → die listing the candidates (see _candidates_die).
resolve_project_global() {
  local arg="${1:-.}"
  local y d id nm f
  local -a m=()
  # 1) existing path on disk → realpath-id across all yards.
  if [ -e "$arg" ]; then
    id="$(project_id "$arg")"
    while IFS= read -r y; do
      d="$(state_dir_for_yard "$y")"
      [ -f "$d/$id.json" ] && m+=("$y"$'\t'"$id")
    done < <(yard_registry_names)
    case "${#m[@]}" in
      1) printf '%s\n' "${m[0]}"; return 0 ;;
      0) die "'$(basename -- "$(realpath -- "$arg")")' is not in any yard — run: ${PROG:-yard} sync $arg (or: bind $arg)" ;;
      *) _candidates_die "$arg" "${m[@]}" ;;
    esac
  fi
  # 2) exact id across yards.
  m=()
  while IFS= read -r y; do
    d="$(state_dir_for_yard "$y")"
    [ -f "$d/$arg.json" ] && m+=("$y"$'\t'"$arg")
  done < <(yard_registry_names)
  case "${#m[@]}" in
    1) printf '%s\n' "${m[0]}"; return 0 ;;
    0) ;;
    *) _candidates_die "$arg" "${m[@]}" ;;
  esac
  # 3) name (case-insensitive) across yards.
  m=()
  while IFS= read -r y; do
    d="$(state_dir_for_yard "$y")"
    [ -d "$d" ] || continue
    for f in "$d"/*.json; do
      [ -e "$f" ] || continue
      id="$(basename "$f" .json)"
      nm="$(_state_field "$d" "$id" name)"
      [ "${nm,,}" = "${arg,,}" ] && m+=("$y"$'\t'"$id")
    done
  done < <(yard_registry_names)
  case "${#m[@]}" in
    1) printf '%s\n' "${m[0]}"; return 0 ;;
    0) ;;
    *) _candidates_die "$arg" "${m[@]}" ;;
  esac
  # 4) qualified <yard>/<rest> (arg is not an existing path; prefix must be a registry name).
  case "$arg" in
    */*)
      local pfx="${arg%%/*}" rest="${arg#*/}" names
      # Capture the registry once and match with a here-string: `yard_registry_names | grep -q`
      # under pipefail can return 141 (SIGPIPE, grep closes the pipe on first match) and silently
      # skip qualified-name resolution.
      names="$(yard_registry_names)"
      if [ -n "$rest" ] && grep -qxF "$pfx" <<<"$names"; then
        d="$(state_dir_for_yard "$pfx")"
        [ -f "$d/$rest.json" ] && { printf '%s\t%s\n' "$pfx" "$rest"; return 0; }
        local -a q=()
        if [ -d "$d" ]; then
          for f in "$d"/*.json; do
            [ -e "$f" ] || continue
            id="$(basename "$f" .json)"; nm="$(_state_field "$d" "$id" name)"
            [ "${nm,,}" = "${rest,,}" ] && q+=("$pfx"$'\t'"$id")
          done
        fi
        case "${#q[@]}" in
          1) printf '%s\n' "${q[0]}"; return 0 ;;
          0) die "no project '$rest' in yard '$pfx' — see: ${PROG:-yard} -Y $pfx list" ;;
          *) _candidates_die "$arg" "${q[@]}" ;;
        esac
      fi
      ;;
  esac
  die "no project '$arg' in any yard — see: ${PROG:-yard} list (a project synced from another machine shows under '${PROG:-yard} list --live'; address it with an explicit -Y <yard>, which registers it on demand)"
}

# reexec_in_yard <name> — re-run THIS command in a different yard context, re-using the exact
# path + argv lib.sh saved. The child re-parses everything with the yard's config loaded; the
# EXPLICIT marker both disables the child's own global resolution and guards against a re-exec
# loop (an already-explicit call never re-execs). Execs — it does not return on success.
reexec_in_yard() {
  local name="${1:?reexec_in_yard needs a yard}"
  [ -n "${SUBYARD_YARD_EXPLICIT:-}" ] && return 0
  exec env SUBYARD_YARD="$name" SUBYARD_YARD_EXPLICIT=1 \
    "$SUBYARD_SCRIPT_PATH" ${SUBYARD_SCRIPT_ARGV[@]+"${SUBYARD_SCRIPT_ARGV[@]}"}
}

# resolve_project_ctx <arg> — resolve a project for a command and land in its yard. Sets
# RESOLVED_ID for the caller. With an explicit context (-Y/@, or a re-exec'd child) it resolves
# within that context (resolve_project_id). Otherwise it resolves across all yards and, if the
# project lives elsewhere, re-execs there (never returns). MUST be called directly, NOT inside
# $(…): it may exec, and a command-substitution subshell would exec the subshell instead.
resolve_project_ctx() {
  local arg="${1:-.}"
  # RESOLVED_ID is the out-parameter (read by the caller); shellcheck can't see that use.
  # shellcheck disable=SC2034
  if [ -n "${SUBYARD_YARD_EXPLICIT:-}" ]; then
    RESOLVED_ID="$(resolve_project_id "$arg")"
    return 0
  fi
  local line yard id
  line="$(resolve_project_global "$arg")"   # dies (via set -e) on 0 / ambiguous
  yard="${line%%$'\t'*}"; id="${line#*$'\t'}"
  [ "$yard" = "${YARD_NAME:-default}" ] || reexec_in_yard "$yard"   # execs when elsewhere
  # shellcheck disable=SC2034  # out-parameter read by the caller
  RESOLVED_ID="$id"
}

# route_sync_target <id> <at_yard> — pick the target yard for a create/refresh command
# (sync/bind/clone) and re-exec there if it is not the loaded context; return 0 to proceed
# in-context. <at_yard> is a trailing `@<name>` ("" if none). Explicit context (-Y/@): no path
# routing — a conflicting `@` dies, else proceed here. Otherwise the id's existing registrations
# decide: 0 → stay here; 1 → route to that yard; 2+ → die demanding a qualifier. MUST be called
# directly, NOT inside $(…) (it may exec).
route_sync_target() {
  local id="$1" at="$2" here="${YARD_NAME:-default}"
  if [ -n "${SUBYARD_YARD_EXPLICIT:-}" ]; then
    [ -z "$at" ] || [ "$at" = "$here" ] \
      || die "conflicting yard: context is '-Y $here' but '@$at' was given — drop one"
    return 0
  fi
  local target="" y d
  if [ -n "$at" ]; then
    target="$at"
  else
    local -a in=()
    while IFS= read -r y; do
      d="$(state_dir_for_yard "$y")"
      [ -n "$id" ] && [ -f "$d/$id.json" ] && in+=("$y")
    done < <(yard_registry_names)
    case "${#in[@]}" in
      0) target="$here" ;;
      1) target="${in[0]}" ;;
      *) die "$(printf "this path is already in multiple yards (%s) — pick one with '@<yard>' or -Y <yard>" "$(printf '%s ' "${in[@]}" | sed 's/ $//')")" ;;
    esac
  fi
  if [ "$target" != default ] && [ "$target" != "$here" ]; then
    yard_env_file "$target" >/dev/null 2>&1 \
      || die "unknown yard '$target' — known yards: $(yard_registry_names | tr '\n' ' ')"
  fi
  [ "$target" = "$here" ] && return 0
  reexec_in_yard "$target"
}

# --- remote data plane -------------------------------------------------------
# A remote context (YARD_TYPE=remote) has NO local incus: the data-plane scripts reach the yard
# only through its ProxyJump ssh alias ($SSH_HOST = yard-<name>). These helpers replace the incus
# RUNNING probe with an ssh reachability probe and centralise the "start it on the owner host" hint.

# yard_is_remote — true when the loaded context is a remote yard.
yard_is_remote() { [ "${YARD_TYPE:-local}" = remote ]; }

# remote_start_hint — the fixed "start it elsewhere" tail for a remote yard's die messages
# (the yard is owned by another host; it cannot be started from here).
remote_start_hint() {
  printf 'start it on the owner host: %s remote … / ssh %s yard%s start' \
    "${PROG:-yard}" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:+ -Y $REMOTE_YARD}"
}

# yard_reachable — probe the yard over its ssh alias (BatchMode + short timeout so a down yard
# fails fast). The data-plane analogue of the local "instance is RUNNING" check.
yard_reachable() { ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_HOST:-yard}" true 2>/dev/null; }

# require_remote_reachable — die with the owner-host hint unless the remote yard answers ssh.
# Callers use it in place of the incus preflight under a remote context.
require_remote_reachable() {
  yard_reachable && return 0
  die "the remote yard is unreachable — $(remote_start_hint)"
}

# --- yard-side meta ----------------------------------------------------------
# On sync/clone we drop /srv/workspaces/<id>/.subyard-meta.json next to src/ so any controller
# (a second laptop) can discover what the yard holds even without local state. Best-effort:
# a meta failure only WARNs, it never fails the sync/clone.

# yard_meta_json <id> <name> <mode> — the schema-1 meta body; origin is this controller's host.
yard_meta_json() {
  jq -cn --argjson schema 1 --arg projectId "$1" --arg name "$2" --arg mode "$3" \
    --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg origin "$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)" \
    '{schema:$schema,projectId:$projectId,name:$name,mode:$mode,importedAt:$importedAt,origin:$origin}'
}

# write_yard_meta <id> <name> <mode> — write the meta over the SAME transport the copy used:
# ssh when the alias is up (works for local and remote), else incus exec for a LOCAL yard.
# Always returns 0 — on any failure it warns and moves on (never breaks sync/clone).
write_yard_meta() {
  local id="$1" name="$2" mode="$3" json dir dst
  dir="/srv/workspaces/$id"; dst="$dir/.subyard-meta.json"
  json="$(yard_meta_json "$id" "$name" "$mode" 2>/dev/null)" \
    || { warn "could not build yard meta for '$name' (skipped; non-fatal)"; return 0; }
  # Attempt the ssh write directly (BatchMode + short timeout is its own reachability probe) —
  # saves a round-trip vs probe-then-write. On failure fall back to incus for a LOCAL yard, with
  # --user/--group so the meta is dev-owned in the dev-owned tree (not root-owned via `sh -c`).
  if printf '%s\n' "$json" | ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_HOST:-yard}" "cat > '$dst'" 2>/dev/null; then
    return 0
  fi
  if ! yard_is_remote && command -v incus >/dev/null 2>&1; then
    printf '%s\n' "$json" \
      | incus exec "${INSTANCE_NAME:-yard}" --project "${INCUS_PROJECT:-subyard}" \
          --user "${DEV_UID:-1000}" --group "${DEV_UID:-1000}" -- \
          sh -c "cat > '$dst'" 2>/dev/null \
      && return 0
  fi
  warn "could not write yard meta for '$name' (non-fatal)"; return 0
}

# --- yard-side reconcile (list --live) ---------------------------------------
# `list --live`, and register-on-demand in remove/code, read the yard's meta files over the
# same transport. Non-fatal: an unreachable yard yields no rows, never a hang or a die.

# _yard_meta_stream <ssh_host> <remote:0|1> <instance> <project> — cat every meta in the yard
# (concatenated JSON objects) via ssh (remote, or local when the alias is up) else incus exec.
_yard_meta_stream() {
  local host="$1" remote="$2" inst="$3" proj="$4"
  local cmd='for f in /srv/workspaces/*/.subyard-meta.json; do [ -e "$f" ] || continue; cat "$f"; printf "\n"; done'
  if [ "$remote" = 1 ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$cmd" 2>/dev/null || true
  elif ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
    ssh "$host" "$cmd" 2>/dev/null || true
  elif command -v incus >/dev/null 2>&1; then
    incus exec "$inst" --project "$proj" -- sh -c "$cmd" 2>/dev/null || true
  fi
}

# _yard_meta_parse — stdin: concatenated meta JSON → one `id\tname\tmode` line per object.
_yard_meta_parse() {
  jq -r 'select(type=="object") | [.projectId,(.name//""),(.mode//"")] | @tsv' 2>/dev/null || true
}

# yard_live_projects — meta rows (id\tname\tmode) for the ACTIVE context's yard.
yard_live_projects() {
  local remote=0; yard_is_remote && remote=1
  _yard_meta_stream "${SSH_HOST:-yard}" "$remote" "${INSTANCE_NAME:-yard}" "${INCUS_PROJECT:-subyard}" \
    | _yard_meta_parse
}

# _yard_env_peek <name> <VAR> — read one KEY=VALUE from a yard's env file without sourcing it.
# Prints nothing (and still returns 0) when the yard has no env file — e.g. the default yard —
# so a `var="$(_yard_env_peek …)"` under `set -e` never aborts; callers fall back to defaults.
_yard_env_peek() {
  local f; f="$(yard_env_file "$1" 2>/dev/null)" || return 0
  [ -r "$f" ] && yard_env_val "$f" "$2"   # canonical reader (indent-tolerant, quote-stripping)
  return 0
}

# yard_live_projects_for <name> — meta rows for ANY registry yard (used by the all-yards
# --live view). Derives the yard's ssh alias / instance / project the same way lib.sh does,
# honoring an explicit override in the env file.
yard_live_projects_for() {
  local y="$1" type host inst proj remote=0
  type="$(_yard_env_peek "$y" YARD_TYPE)"; [ "$type" = remote ] && remote=1
  host="$(_yard_env_peek "$y" SSH_HOST)"
  inst="$(_yard_env_peek "$y" INSTANCE_NAME)"
  proj="$(_yard_env_peek "$y" INCUS_PROJECT)"
  case "$y" in
    default) : "${host:=yard}"; : "${inst:=yard}"; : "${proj:=subyard}" ;;
    *)       : "${host:=yard-$y}"; : "${inst:=yard-$y}"; : "${proj:=subyard-$y}" ;;
  esac
  _yard_meta_stream "$host" "$remote" "$inst" "$proj" | _yard_meta_parse
}

# resolve_project_id_soft <arg> — like resolve_project_id but returns 1 instead of dying when
# nothing matches (so callers can try a yard-side reconcile before giving up).
resolve_project_id_soft() {
  local arg="${1:-.}" id nm
  if [ -e "$arg" ]; then
    id="$(project_id "$arg" 2>/dev/null || true)"
    [ -n "$id" ] && state_exists "$id" && { printf '%s\n' "$id"; return 0; }
  fi
  state_exists "$arg" && { printf '%s\n' "$arg"; return 0; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    nm="$(state_get "$id" name)"
    [ "${nm,,}" = "${arg,,}" ] && { printf '%s\n' "$id"; return 0; }
  done < <(state_ids)
  return 1
}

# maybe_reconcile <arg> — register-on-demand: under an EXPLICIT context, if <arg> is not in
# local state but the active yard holds a project of that id/name (per its meta), write a
# minimal local record (hostPath empty) so remove/code can act on it. Best-effort; the
# subsequent resolve_project_ctx then finds it. Does nothing without an explicit context.
maybe_reconcile() {
  [ -n "${SUBYARD_YARD_EXPLICIT:-}" ] || return 0
  local arg="${1:-.}" yid ynm ymode
  resolve_project_id_soft "$arg" >/dev/null 2>&1 && return 0   # already known locally
  while IFS=$'\t' read -r yid ynm ymode; do
    [ -n "$yid" ] || continue
    if [ "$arg" = "$yid" ] || [ "${arg,,}" = "${ynm,,}" ]; then
      state_write "$yid" "$ynm" "" "$(yard_path_for "$yid")" "$ymode" "${SSH_HOST:-yard}"
      warn "registered '$ynm' from the yard on demand (no host path recorded; export/sync from this machine need one — re-add with '$(yard_cmd_hint) sync <path>')"
      return 0
    fi
  done < <(yard_live_projects)
  return 0
}
