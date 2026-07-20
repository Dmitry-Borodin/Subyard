#!/usr/bin/env bash
# resolver.sh — in-context and cross-yard project resolution/routing.
# shellcheck disable=SC2034 # RESOLVED_ID is an intentional caller-visible out-parameter.

[ -n "${SUBYARD_STATE_RESOLVER_SOURCED:-}" ] && return 0
SUBYARD_STATE_RESOLVER_SOURCED=1

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

# state_dir_for_yard <name> — machine-local project state dir for any yard, provided by registry.sh.

# _state_field <dir> <id> <key> — read one string field from a state file in an arbitrary
# yard's state dir (missing file/key → empty). The cross-yard analogue of state_get, which
# is pinned to the loaded context's $STATE_DIR.
_state_field() {
  local file="$1/$2.json"
  [ -f "$file" ] || return 0
  state_record_valid_file "$file" "$2" \
    || { printf 'invalid project state %s (expected schema %s)\n' "$file" "$STATE_SCHEMA" >&2; return 1; }
  jq -r --arg k "$3" '.[$k] // ""' "$file"
}

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
# path + argv runtime.sh saved. The child re-parses everything with the yard's config loaded; the
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
