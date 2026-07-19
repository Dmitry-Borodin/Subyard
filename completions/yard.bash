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

# Registry yard names: 'default' plus the basename of every *.env under private/yards/ and
# ~/.config/subyard/yards/ — read cheaply in the shell (NEVER invoke incus). $2, if set, is a
# prefix emitted before each name (e.g. '@' for the first-token sugar). Mirrors lib.sh's
# yard_registry_names so completion and the CLI agree on what a valid yard name is.
_yard_yards() {
  local repo pfx="${2:-}" d f n home
  printf '%s%s\n' "$pfx" default
  repo="$(_yard_repo "$1")" || return 0
  local dirs=( "$repo/private/yards" )
  home="$(_yard_config_home "$1")" || home=""
  [ -n "$home" ] && dirs+=( "$home/yards" )
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.env; do
      [ -e "$f" ] || continue
      n="$(basename "$f" .env)"; printf '%s%s\n' "$pfx" "$n"
    done
  done
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

  local globals='-Y --yard -h --help -l --list -V --version -y --yes'

  # A named-yard context may precede the command: -Y <name> / --yard <name> / --yard=<name>
  # / @<name>. Complete its VALUE with registry yard names, and skip it when locating the
  # command slot below.
  if [ "$prev" = "-Y" ] || [ "$prev" = "--yard" ]; then
    local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_yards "${COMP_WORDS[0]}")" -- "$cur") ); return 0
  fi
  case "$cur" in
    @*)       local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_yards "${COMP_WORDS[0]}" @)" -- "$cur") ); return 0 ;;
    --yard=*) local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_yards "${COMP_WORDS[0]}" '--yard=')" -- "$cur") ); return 0 ;;
  esac

  # Command slot: 1, or shifted past a leading context selector.
  local cmdidx=1
  case "${COMP_WORDS[1]:-}" in
    -Y | --yard)     cmdidx=3 ;;
    --yard=* | @?*)  cmdidx=2 ;;
  esac

  # The command position: a global option or a command name.
  if [ "$cword" -eq "$cmdidx" ]; then
    local cmds
    cmds="$("${COMP_WORDS[0]}" --list 2>/dev/null)"
    [ -n "$cmds" ] || cmds='check init start status logs usage shell provision stop teardown sync bind clone list code export remove up down info yards remote emu staging'
    case "$cur" in
      -*) COMPREPLY=( $(compgen -W "$globals" -- "$cur") ) ;;
      *)  COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ) ;;
    esac
    return 0
  fi

  cmd="${COMP_WORDS[cmdidx]}"

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
    code|shell)
      # `yard code` and `yard shell` take a project NAME (from `yard list`) or a directory path.
      if [[ "$cur" == -* ]]; then
        if [ "$cmd" = shell ]; then COMPREPLY=( $(compgen -W '--root --yes --help' -- "$cur") )
        else COMPREPLY=( $(compgen -W '--yes' -- "$cur") ); fi
      else
        local IFS=$'\n'  # keep project names with spaces intact
        COMPREPLY=( $(compgen -W "$(_yard_projects "${COMP_WORDS[0]}")" -- "$cur") )
        COMPREPLY+=( $(compgen -d -- "$cur") )
      fi
      ;;
    teardown|uninstall) COMPREPLY=( $(compgen -W '--keep-data --yes' -- "$cur") ) ;;
    stop) COMPREPLY=( $(compgen -W '--force --yes --help' -- "$cur") ) ;;
    init|setup|check|list|logs|usage|start|yards) COMPREPLY=( $(compgen -W '--yes --help' -- "$cur") ) ;;
    status) COMPREPLY=( $(compgen -W '--all --yes --help' -- "$cur") ) ;;
    remote)
      # remote <add|repair-key|remove|list>; repair/remove take a registered yard name.
      if [ "$cword" -eq "$((cmdidx + 1))" ]; then COMPREPLY=( $(compgen -W 'add repair-key remove list' -- "$cur") )
      elif [ "${COMP_WORDS[cmdidx+1]}" = remove ] || [ "${COMP_WORDS[cmdidx+1]}" = repair-key ]; then local IFS=$'\n'; COMPREPLY=( $(compgen -W "$(_yard_yards "${COMP_WORDS[0]}")" -- "$cur") )
      elif [ "${COMP_WORDS[cmdidx+1]}" = add ]; then [[ "$cur" == -* ]] && COMPREPLY=( $(compgen -W '--yard --yes' -- "$cur") )
      else COMPREPLY=( $(compgen -W '--yes' -- "$cur") ); fi
      ;;
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
      ;;  # otherwise: leave to default
  esac
  return 0
}

complete -F _yard yard sy
