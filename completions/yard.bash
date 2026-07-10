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
    [ -n "$cmds" ] || cmds='check init start status logs usage ssh shell provision stop teardown sync bind clone list code export remove up down info emu staging'
    case "$cur" in
      -*) COMPREPLY=( $(compgen -W "$globals" -- "$cur") ) ;;
      *)  COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ) ;;
    esac
    return 0
  fi

  cmd="${COMP_WORDS[1]}"

  case "$cmd" in
    up)
      # up [path|name] [--rebuild]
      [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--rebuild --yes' -- "$cur") ) \
        || { local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_projects "${COMP_WORDS[0]}")" -- "$cur") ); COMPREPLY+=( $(compgen -d -- "$cur") ); }
      ;;
    down|info)
      [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--yes' -- "$cur") ) \
        || { local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_projects "${COMP_WORDS[0]}")" -- "$cur") ); COMPREPLY+=( $(compgen -d -- "$cur") ); }
      ;;
    remove) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--soft --yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
    emu)
      # emu <up|stop|status|adb|view|tunnel|down>; `view` also takes --control/--no-control.
      if [ "$cword" -eq 2 ]; then COMPREPLY=( $(compgen -W 'up stop status adb view tunnel down' -- "$cur") )
      elif [ "${COMP_WORDS[2]}" = view ]; then COMPREPLY=( $(compgen -W '--no-control --view-only --control --yes' -- "$cur") )
      else COMPREPLY=( $(compgen -W '--yes' -- "$cur") ); fi
      ;;
    sync|bind)
      if [ "$prev" = "--target" ]; then COMPREPLY=( $(compgen -W "yard $(_yard_profiles "${COMP_WORDS[0]}")" -- "$cur") ); return 0; fi
      [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--target --yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") )
      ;;
    export) [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--yes' -- "$cur") ) || COMPREPLY=( $(compgen -d -- "$cur") ) ;;
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
    init|setup|check|list|logs|usage|start|stop) COMPREPLY=( $(compgen -W '--yes --help' -- "$cur") ) ;;
    clone)
      if [ "$prev" = "--target" ]; then COMPREPLY=( $(compgen -W "yard $(_yard_profiles "${COMP_WORDS[0]}")" -- "$cur") ); return 0; fi
      [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--target --yes' -- "$cur") ) ;;
    *)
      # Profile-resource command (emu handled above for its bridge flags)? complete its verbs from
      # the registry (`yard --resources` => "<command>\t<verbs>"), so new resources need no edit here.
      local _rc _rv _verbs=''
      while IFS=$'\t' read -r _rc _rv; do [ "$_rc" = "$cmd" ] && { _verbs="$_rv"; break; }; done \
        < <("${COMP_WORDS[0]}" --resources 2>/dev/null)
      if [ -n "$_verbs" ]; then
        if [ "$cword" -eq 2 ]; then COMPREPLY=( $(compgen -W "$_verbs" -- "$cur") )
        else COMPREPLY=( $(compgen -W '--yes' -- "$cur") ); fi
      fi
      ;;  # otherwise (ssh, …): leave to default
  esac
  return 0
}

complete -F _yard yard sy
