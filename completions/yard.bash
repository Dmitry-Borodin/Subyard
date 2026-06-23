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
    sync|export|code) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
    teardown|uninstall) COMPREPLY=( $(compgen -W '--keep-data --yes' -- "$cur") ) ;;
    init|setup|check|list|status|logs|start|stop|up|down) COMPREPLY=( $(compgen -W '--yes --help' -- "$cur") ) ;;
    *) ;;  # clone (url), ssh (pass-through): leave to default
  esac
  return 0
}

complete -F _yard yard sy
