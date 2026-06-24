# shellcheck shell=bash
# yard.bash — bash completion for the `yard` (and `sy`) CLI.
# Self-contained: no bash-completion package required. Top-level commands come
# from `yard --list` so they stay in sync with bin/yard; profile names are read
# from the repo's config/profiles/ (resolved via the yard symlink on PATH).

_yard_repo() {
  local bin
  bin="$(command -v "${1:-yard}" 2>/dev/null)" || return 1
  bin="$(readlink -f "$bin" 2>/dev/null)" || return 1
  ( cd "$(dirname "$bin")/.." && pwd )
}

_yard_profiles() {
  local repo; repo="$(_yard_repo "$1")" || return 0
  local d="$repo/config/profiles"
  [ -d "$d" ] || return 0
  ( cd "$d" && ls -1 ./*.conf 2>/dev/null | sed 's,^\./,,;s,\.conf$,,' )
}

# Host-side state home: honor an explicit override, else derive the same default as
# config/host.env (so completion and the CLI can never disagree on where state lives).
_yard_config_home() {
  if [ -n "${SUBYARD_CONFIG_HOME:-}" ]; then printf '%s\n' "$SUBYARD_CONFIG_HOME"; return 0; fi
  local repo; repo="$(_yard_repo "$1")" || return 1
  [ -r "$repo/config/host.env" ] || return 1
  ( . "$repo/config/host.env" >/dev/null 2>&1; printf '%s\n' "${SUBYARD_CONFIG_HOME:-}" )
}

# Project names from machine-local state ($SUBYARD_CONFIG_HOME/projects/*.json) — the
# same names `yard list` shows and `yard code <name>` resolves. No jq: pull the "name"
# field with sed so completion stays dependency-free.
_yard_projects() {
  local home; home="$(_yard_config_home "$1")" || return 0
  local d="$home/projects" f name
  [ -n "$home" ] && [ -d "$d" ] || return 0
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -n1)"
    [ -n "$name" ] && printf '%s\n' "$name"
  done
}

_yard() {
  local cur prev words cword cmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cword=$COMP_CWORD

  local globals='-h --help -l --list -V --version -y --yes'

  # First word: a global option or a command.
  if [ "$cword" -eq 1 ]; then
    local cmds
    cmds="$("${COMP_WORDS[0]}" --list 2>/dev/null)"
    [ -n "$cmds" ] || cmds='init teardown check import sync export remove clone code ssh agent list status logs start stop'
    case "$cur" in
      -*) COMPREPLY=( $(compgen -W "$globals" -- "$cur") ) ;;
      *)  COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ) ;;
    esac
    return 0
  fi

  cmd="${COMP_WORDS[1]}"

  case "$cmd" in
    agent)
      # agent <sub> [path] [--profile N]
      local sub="${COMP_WORDS[2]:-}"
      if [ "$cword" -eq 2 ]; then
        COMPREPLY=( $(compgen -W 'up info shell exec down destroy list' -- "$cur") )
        return 0
      fi
      if [ "$prev" = "--profile" ]; then
        COMPREPLY=( $(compgen -W "$(_yard_profiles "${COMP_WORDS[0]}")" -- "$cur") )
        return 0
      fi
      case "$cur" in
        -*) [ "$sub" = up ] && COMPREPLY=( $(compgen -W '--profile --rebuild --yes' -- "$cur") ) ;;
        *)  case "$sub" in
              up|info|shell|exec|down|destroy) COMPREPLY=( $(compgen -d -- "$cur") ) ;;
            esac ;;
      esac
      ;;
    import) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--bind --yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
    remove) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--purge --yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
    sync|export) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
    code)
      # `yard code` takes a project NAME (from `yard list`) or a directory path.
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W '--yes' -- "$cur") )
      else
        local IFS=$'\n'  # keep project names with spaces intact
        COMPREPLY=( $(compgen -W "$(_yard_projects "${COMP_WORDS[0]}")" -- "$cur") )
        COMPREPLY+=( $(compgen -d -- "$cur") )
      fi
      ;;
    teardown|uninstall) COMPREPLY=( $(compgen -W '--keep-data --yes' -- "$cur") ) ;;
    status) COMPREPLY=( $(compgen -W '--space --yes --help' -- "$cur") ) ;;
    init|setup|check|list|logs|start|stop|up|down) COMPREPLY=( $(compgen -W '--yes --help' -- "$cur") ) ;;
    *) ;;  # clone (url), ssh (pass-through): leave to default
  esac
  return 0
}

complete -F _yard yard sy
