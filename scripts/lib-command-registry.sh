#!/usr/bin/env bash
# lib-command-registry.sh — pure reader for config/commands.registry.
# Source-only: does not load Subyard config, touch host state or execute handlers.
# shellcheck disable=SC2034 # COMMAND_* are out-parameters consumed by registry callers.

[ -n "${SUBYARD_COMMAND_REGISTRY_SOURCED:-}" ] && return 0
SUBYARD_COMMAND_REGISTRY_SOURCED=1

SUBYARD_COMMAND_REGISTRY_FILE="${SUBYARD_COMMAND_REGISTRY_FILE:-}"

command_registry_file() {
  if [ -n "$SUBYARD_COMMAND_REGISTRY_FILE" ]; then
    printf '%s\n' "$SUBYARD_COMMAND_REGISTRY_FILE"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../config/commands.registry\n' "$here"
}

command_registry_rows() {
  local file
  file="$(command_registry_file)"
  [ -r "$file" ] || return 1
  sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$file"
}

command_registry_alias_matches() { # <aliases-csv> <candidate>
  local aliases="$1" candidate="$2" alias
  [ -n "$aliases" ] || return 1
  local IFS=,
  for alias in $aliases; do [ "$alias" = "$candidate" ] && return 0; done
  return 1
}

command_registry_lookup() { # <name-or-alias>; sets COMMAND_*
  local candidate="${1:?command_registry_lookup needs a command}"
  local name aliases handler arg0 remote visibility section completion display summary options verbs
  COMMAND_NAME=''
  COMMAND_ALIASES=''
  COMMAND_HANDLER=''
  COMMAND_ARG0=''
  COMMAND_REMOTE=''
  COMMAND_VISIBILITY=''
  COMMAND_SECTION=''
  COMMAND_COMPLETION=''
  COMMAND_DISPLAY=''
  COMMAND_SUMMARY=''
  COMMAND_OPTIONS=''
  COMMAND_VERBS=''
  while IFS='|' read -r name aliases handler arg0 remote visibility section completion display summary options verbs; do
    [ "$name" = "$candidate" ] || command_registry_alias_matches "$aliases" "$candidate" || continue
    COMMAND_NAME="$name"
    COMMAND_ALIASES="$aliases"
    COMMAND_HANDLER="$handler"
    COMMAND_ARG0="$arg0"
    COMMAND_REMOTE="$remote"
    COMMAND_VISIBILITY="$visibility"
    COMMAND_SECTION="$section"
    COMMAND_COMPLETION="$completion"
    COMMAND_DISPLAY="$display"
    COMMAND_SUMMARY="$summary"
    COMMAND_OPTIONS="$options"
    COMMAND_VERBS="$verbs"
    return 0
  done < <(command_registry_rows)
  return 1
}

command_registry_list() { # [public|all]
  local scope="${1:-public}" name aliases handler arg0 remote visibility section completion display summary options verbs
  while IFS='|' read -r name aliases handler arg0 remote visibility section completion display summary options verbs; do
    [ "$scope" = all ] || [ "$visibility" = public ] || continue
    printf '%s\n' "$name"
  done < <(command_registry_rows)
}

command_registry_help_rows() { # <section> -> display|summary
  local wanted="$1" name aliases handler arg0 remote visibility section completion display summary options verbs
  while IFS='|' read -r name aliases handler arg0 remote visibility section completion display summary options verbs; do
    [ "$visibility" = public ] && [ "$section" = "$wanted" ] || continue
    printf '%s|%s\n' "$display" "$summary"
  done < <(command_registry_rows)
}

command_registry_completion() { # <name-or-alias>
  command_registry_lookup "$1" || return 1
  printf '%s\n' "$COMMAND_COMPLETION"
}

command_registry_options() { # <name-or-alias>
  command_registry_lookup "$1" || return 1
  printf '%s\n' "$COMMAND_OPTIONS"
}

command_registry_verbs() { # <name-or-alias>
  command_registry_lookup "$1" || return 1
  printf '%s\n' "$COMMAND_VERBS"
}

command_registry_manifest() {
  command_registry_rows
}

command_registry_validate() {
  local line=0 name aliases handler arg0 remote visibility section completion display summary options verbs alias seen=' '
  local -a alias_list=()
  while IFS='|' read -r name aliases handler arg0 remote visibility section completion display summary options verbs; do
    line=$((line + 1))
    [ -n "$name" ] && [ -n "$handler" ] && [ -n "$remote" ] && [ -n "$visibility" ] \
      && [ -n "$section" ] && [ -n "$completion" ] && [ -n "$display" ] && [ -n "$summary" ] \
      || { printf 'invalid command registry row %s\n' "$line" >&2; return 1; }
    case "$name" in *[!A-Za-z0-9_-]*) printf 'invalid command name: %s\n' "$name" >&2; return 1 ;; esac
    case "$handler" in
      @help | @resource) ;;
      '' | /* | -* | *[!A-Za-z0-9._/-]* | *'..'*)
        printf 'invalid command handler for %s: %s\n' "$name" "$handler" >&2; return 1 ;;
    esac
    case "$arg0" in *[!A-Za-z0-9_-]*) printf 'invalid handler argument for %s\n' "$name" >&2; return 1 ;; esac
    case "$remote" in local | forward | deny) ;; *) printf 'invalid remote plane for %s\n' "$name" >&2; return 1 ;; esac
    case "$visibility" in public | hidden) ;; *) printf 'invalid visibility for %s\n' "$name" >&2; return 1 ;; esac
    case "$section$completion" in *[!A-Za-z0-9_-]*) printf 'invalid command metadata for %s\n' "$name" >&2; return 1 ;; esac
    case "$options" in *[!A-Za-z0-9_./=[:space:]-]*) printf 'invalid completion option list for %s\n' "$name" >&2; return 1 ;; esac
    case "$verbs" in *[!A-Za-z0-9_[:space:]-]*) printf 'invalid completion verb list for %s\n' "$name" >&2; return 1 ;; esac
    case "$seen" in *" $name "*) printf 'duplicate command: %s\n' "$name" >&2; return 1 ;; esac
    seen+="$name "
    if [ -n "$aliases" ]; then
      IFS=, read -r -a alias_list <<<"$aliases"
      for alias in "${alias_list[@]}"; do
        case "$alias" in '' | *[!A-Za-z0-9_-]*) printf 'invalid alias for %s: %s\n' "$name" "$alias" >&2; return 1 ;; esac
        case "$seen" in *" $alias "*) printf 'duplicate command or alias: %s\n' "$alias" >&2; return 1 ;; esac
        seen+="$alias "
      done
    fi
  done < <(command_registry_rows)
  [ "$line" -gt 0 ]
}
