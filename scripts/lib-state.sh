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

# Yard metadata is dev-owned and therefore untrusted at the host boundary. These validators guard
# every metadata-driven state write: projectId becomes a filename, and target later selects a
# profile path. Never let either carry path syntax back onto the owner/controller host.
state_project_id_valid() {
  case "${1:-}" in '' | -* | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

state_project_mode_valid() { case "${1:-}" in sync | git | bind) return 0 ;; *) return 1 ;; esac; }

state_project_target_valid() {
  [ -z "${1:-}" ] || [ "$1" = yard ] || _yard_valid_name "$1"
}

state_yard_record_valid() {
  state_project_id_valid "$1" && state_project_mode_valid "$2" && state_project_target_valid "$3"
}

# state_upsert_yard <id> <name> <mode> <target-or-empty> <ssh-host> — converge facts learned
# from the yard while preserving controller-specific state. In particular, never import another
# controller's hostPath and never erase a real owner-local one. Existing timestamps stay stable;
# a new synthetic record is explicitly marked so its empty path renders as `(yard)`.
state_upsert_yard() {
  local id="$1" name="$2" mode="$3" target="$4" ssh_host="$5" f
  state_yard_record_valid "$id" "$mode" "$target" || return 1
  f="$(state_file "$id")"
  if [ ! -f "$f" ]; then
    state_write "$id" "$name" "" "$(yard_path_for "$id")" "$mode" "$ssh_host"
    [ -z "$target" ] || state_set "$id" target "$target"
    state_set "$id" registrySource yard
    return 0
  fi
  jq --arg name "$name" --arg mode "$mode" --arg target "$target" \
     --arg yardPath "$(yard_path_for "$id")" --arg sshHost "$ssh_host" '
      .name=$name | .mode=$mode | .yardPath=$yardPath | .sshHost=$sshHost |
      if $target != "" then .target=$target else . end |
      if (.hostPath // "") == "" then .registrySource="yard" else del(.registrySource) end
    ' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}
# List ids of all known projects (empty output if none).
state_ids() {
  [ -d "$STATE_DIR" ] || return 0
  local f
  for f in "$STATE_DIR"/*.json; do [ -e "$f" ] && basename "$f" .json; done
}

# project_arg_in_context <arg> — once cross-yard resolution has selected and re-execed in a
# yard, turn its copy-pasteable `<yard>/<name-or-id>` selector back into the in-context part.
# Existing paths keep precedence: a real relative path such as `yard/project` is still a path,
# not a qualified selector. This also makes an explicit `yard -Y x code x/project` harmless.
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
    arg="$(project_arg_in_context "$arg")"
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

# remote_start_hint — a command in the ACTIVE remote context. The dispatcher forwards `start`
# to the owner host, so the operator does not need to reconstruct the owner-host ssh command.
remote_start_hint() {
  if [ -n "${YARD_NAME:-}" ] && _yard_valid_name "$YARD_NAME"; then
    printf 'run: %s -Y %s start' "${PROG:-yard}" "$YARD_NAME"
  else
    printf 'start it on the owner host: ssh %s -- yard%s start' \
      "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:+ -Y $REMOTE_YARD}"
  fi
}

# remote_owner_yard_cmd — run one non-interactive yard command in the remote yard's owner-host
# context. Arguments are quoted token-by-token across ssh + the remote login shell. This is the
# control-plane companion to the direct yard data plane and carries no project source path.
remote_owner_yard_cmd() {
  local dest="${REMOTE_DEST:-}" ryard="${REMOTE_YARD:-}" rc='yard' a
  [ -n "$dest" ] || return 1
  [ -n "$ryard" ] && rc="$rc -Y $(printf '%q' "$ryard")"
  for a in "$@"; do rc="$rc $(printf '%q' "$a")"; done
  ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_REMOTE_TIMEOUT:-10}" \
      -o StrictHostKeyChecking=accept-new "$dest" -- bash -lc "$(printf '%q' "$rc")"
}

# Remote project data is copied straight into the yard, bypassing its owner host. Complete the
# operation by converging the owner's machine-local registry through the hidden validated endpoint.
remote_owner_project_upsert() { # <id> <name> <mode> <target>
  remote_owner_yard_cmd _project-state upsert "$1" "$2" "$3" "$4"
}

remote_owner_project_unregister() { # <id>
  remote_owner_yard_cmd _project-state unregister "$1"
}

# remote_alias_configured — distinguish a missing/legacy snippet from a network failure. `ssh -G`
# resolves Includes without opening a connection; the managed alias must expose this context's
# stable HostKeyAlias. A legacy snippet therefore gets the useful "re-run remote add" diagnosis.
remote_alias_configured() {
  local expected cfg got
  expected="$(remote_hostkey_alias "${YARD_NAME:-}" 2>/dev/null)" || return 1
  cfg="$(ssh -G "${SSH_HOST:-yard}" 2>/dev/null)" || return 1
  got="$(awk '$1=="hostkeyalias" { print $2; exit }' <<<"$cfg")"
  [ "$got" = "$expected" ]
}

# yard_reachable — probe the yard over its ssh alias (BatchMode + short timeout so a down yard
# fails fast). Preserve stderr in-memory for classification, but never echo the raw diagnostic:
# ssh/config errors may contain private host aliases or local paths.
REMOTE_SSH_ERROR=''
yard_reachable() {
  if REMOTE_SSH_ERROR="$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${SSH_HOST:-yard}" true 2>&1 >/dev/null)"; then
    REMOTE_SSH_ERROR=''
    return 0
  fi
  return 1
}

# remote_owner_info — control-plane probe used only after the data plane failed. Its success
# separates an unreachable owner host from a stopped yard or a broken loopback proxy/sshd.
remote_owner_info() {
  local dest="${REMOTE_DEST:-}" ryard="${REMOTE_YARD:-}" rc='yard _info'
  [ -n "$dest" ] || return 1
  [ -n "$ryard" ] && rc="yard -Y $(printf '%q' "$ryard") _info"
  ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_REMOTE_TIMEOUT:-5}" \
      -o StrictHostKeyChecking=accept-new "$dest" -- bash -lc "$(printf '%q' "$rc")" 2>/dev/null
}

# require_remote_reachable — classify the failure instead of turning every ssh error into a
# false "start it" hint. Callers use it in place of the local incus preflight.
require_remote_reachable() {
  remote_alias_configured \
    || die "ssh alias '${SSH_HOST:-yard}' is missing or legacy — re-run '$(remote_add_hint "${YARD_NAME:-<name>}" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to regenerate it"
  yard_reachable && return 0

  local json='' state=''
  json="$(remote_owner_info)" \
    || die "the owner host for remote yard '${YARD_NAME:-?}' is unreachable — check its ssh access, host key and network"
  case "$json" in '{'*'}') ;; *) die "the owner host answered, but 'yard _info' did not — check its Subyard installation" ;; esac

  # The owner probe succeeded, so these diagnostics belong to the in-yard ssh hop rather than
  # the ProxyJump host itself.
  case "$REMOTE_SSH_ERROR" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'* | *'Host key verification failed'* | *'Offending '*key*)
      die "ssh host key changed for '$(remote_hostkey_alias "$YARD_NAME")' — access is blocked; verify it on the owner host, then run '${PROG:-yard} remote repair-key $YARD_NAME'" ;;
  esac

  state="$(json_str "$json" state)"
  case "$state" in
    RUNNING) ;;
    STOPPED | FROZEN) die "remote yard state is $state — $(remote_start_hint)" ;;
    '' | UNKNOWN) die "the owner host is reachable, but its Incus state is unknown — check Incus on the owner host" ;;
    *) die "remote yard state is $state — $(remote_start_hint)" ;;
  esac

  case "$REMOTE_SSH_ERROR" in
    *'Permission denied'* | *'no mutual signature algorithm'* | *'Too many authentication failures'*)
      die "the remote yard rejected this controller's ssh key — re-run '$(remote_add_hint "$YARD_NAME" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to authorize it and verify the data plane" ;;
  esac

  case "$REMOTE_SSH_ERROR" in
    *'Could not resolve hostname'* | *'Bad configuration option'* | *'no argument after keyword'* | *'percent_expand'*)
      die "ssh alias '${SSH_HOST:-yard}' is invalid — re-run '$(remote_add_hint "$YARD_NAME" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to regenerate it" ;;
    *'Connection refused'* | *'Connection timed out'* | *'Operation timed out'* | \
    *'kex_exchange_identification'* | *'stdio forwarding failed'* | *'administratively prohibited'* | \
    *'Connection closed'*)
      die "the owner host and remote instance are reachable, but the yard loopback proxy or sshd is not — run '${PROG:-yard} -Y $YARD_NAME status' and check sshd on the owner host" ;;
    *)
      die "the remote yard data plane failed through ssh alias '${SSH_HOST:-yard}' — run 'ssh ${SSH_HOST:-yard} true' to inspect the SSH diagnostic" ;;
  esac
}

# --- yard-side meta ----------------------------------------------------------
# On sync/clone we drop /srv/workspaces/<id>/.subyard-meta.json next to src/ so any controller
# (a second laptop) can discover what the yard holds even without local state. Best-effort:
# a meta failure only WARNs, it never fails the sync/clone.

# yard_meta_json <id> <name> <mode> <target> — schema-1 meta; origin is this controller's host.
yard_meta_json() {
  jq -cn --argjson schema 1 --arg projectId "$1" --arg name "$2" --arg mode "$3" --arg target "$4" \
    --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg origin "$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)" \
    '{schema:$schema,projectId:$projectId,name:$name,mode:$mode,target:$target,importedAt:$importedAt,origin:$origin}'
}

# write_yard_meta <id> <name> <mode> <target> — write meta over the SAME transport the copy used:
# ssh when the alias is up (works for local and remote), else incus exec for a LOCAL yard.
# Always returns 0 — on any failure it warns and moves on (never breaks sync/clone).
write_yard_meta() {
  local id="$1" name="$2" mode="$3" target="$4" json dir dst
  dir="/srv/workspaces/$id"; dst="$dir/.subyard-meta.json"
  json="$(yard_meta_json "$id" "$name" "$mode" "$target" 2>/dev/null)" \
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

# _yard_meta_parse — stdin: concatenated meta JSON → `id\tname\tmode\ttarget` per object.
_yard_meta_parse() {
  jq -r 'select(type=="object") | [.projectId,(.name//""),(.mode//""),(.target//"")] | @tsv' 2>/dev/null || true
}

# yard_live_projects — meta rows (id\tname\tmode\ttarget) for the ACTIVE context's yard.
yard_live_projects() {
  local remote=0; yard_is_remote && remote=1
  _yard_meta_stream "${SSH_HOST:-yard}" "$remote" "${INSTANCE_NAME:-yard}" "${INCUS_PROJECT:-subyard}" \
    | _yard_meta_parse
}

# yard_live_project_count_local — strict owner-side count for `yard _info`. Unlike the
# best-effort list helpers above, this distinguishes an empty running yard (prints 0) from a
# failed/unparseable observation (returns non-zero and prints nothing), so remote controllers can
# retain a last-good count instead of caching a false zero. Project IDs are deduplicated because
# yard-side metadata, not controller-local state, is the source of truth for remote inventory.
yard_live_project_count_local() {
  local inst="${INSTANCE_NAME:-yard}" proj="${INCUS_PROJECT:-subyard}" raw ids
  local cmd='for f in /srv/workspaces/*/.subyard-meta.json; do [ -e "$f" ] || continue; cat "$f"; printf "\n"; done'
  command -v incus >/dev/null 2>&1 || return 1
  raw="$(incus exec "$inst" --project "$proj" -- sh -c "$cmd" 2>/dev/null)" || return 1
  ids="$(jq -r 'select(type == "object" and (.projectId | type == "string") and .projectId != "") | .projectId' \
    <<<"$raw" 2>/dev/null)" || return 1
  awk 'NF && !seen[$0]++ { n++ } END { print n + 0 }' <<<"$ids"
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
  local arg="${1:-.}" yid ynm ymode ytarget
  arg="$(project_arg_in_context "$arg")"
  resolve_project_id_soft "$arg" >/dev/null 2>&1 && return 0   # already known locally
  while IFS=$'\t' read -r yid ynm ymode ytarget; do
    [ -n "$yid" ] || continue
    state_yard_record_valid "$yid" "$ymode" "$ytarget" || continue
    if [ "$arg" = "$yid" ] || [ "${arg,,}" = "${ynm,,}" ]; then
      state_upsert_yard "$yid" "$ynm" "$ymode" "$ytarget" "${SSH_HOST:-yard}"
      warn "registered '$ynm' from the yard on demand (no host path recorded; export/sync from this machine need one — re-add with '$(yard_cmd_hint) sync <path>')"
      return 0
    fi
  done < <(yard_live_projects)
  return 0
}
