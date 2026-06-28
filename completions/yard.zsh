#compdef yard sy
# yard.zsh — zsh completion for the `yard` (and `sy`) CLI.
# Place on $fpath (e.g. ~/.zsh/completions) as `_yard`, or source it directly.
# Top-level commands come from `yard --list`; profiles from config/profiles/.

_yard_repo() {
  local bin
  bin="$(command -v yard 2>/dev/null)" || return 1
  bin="${bin:A}"               # resolve symlink
  print -r -- "${bin:h:h}"     # dirname twice → repo root
}

_yard_profiles() {
  local repo d
  repo="$(_yard_repo)" || return 0
  d="$repo/config/profiles"
  [[ -d $d ]] || return 0
  print -r -- ${(@)$(cd "$d" && print -r -- *.conf(N:r))}
}

# Host-side state home: honor an explicit override, else derive the same default as
# config/host.env (so completion and the CLI agree on where state lives).
_yard_config_home() {
  if [[ -n ${SUBYARD_CONFIG_HOME:-} ]]; then print -r -- "$SUBYARD_CONFIG_HOME"; return 0; fi
  local repo; repo="$(_yard_repo)" || return 1
  [[ -r $repo/config/host.env ]] || return 1
  ( source "$repo/config/host.env" >/dev/null 2>&1; print -r -- "${SUBYARD_CONFIG_HOME:-}" )
}

# Project names from machine-local state ($SUBYARD_CONFIG_HOME/projects/*.json) — the
# same names `yard list` shows and `yard code <name>` resolves. No jq: pull "name" via sed.
_yard_projects() {
  local home d f name
  home="$(_yard_config_home)" || return 0
  d="$home/projects"
  [[ -n $home && -d $d ]] || return 0
  for f in $d/*.json(N); do
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -n1)"
    [[ -n $name ]] && print -r -- "$name"
  done
}

# `yard code` target: a known project name or a directory path.
_yard_code_target() {
  local -a projs; projs=( ${(f)"$(_yard_projects)"} )
  _alternative \
    'projects:project:compadd -a projs' \
    'directories:directory:_files -/'
}

_yard() {
  local -a cmds
  cmds=( ${(f)"$(yard --list 2>/dev/null)"} )
  [[ -n $cmds ]] || cmds=( check init start status logs usage ssh shell provision stop teardown sync bind clone list code export remove up down info emu staging )

  local curcontext="$curcontext" state line
  typeset -A opt_args

  _arguments -C \
    '(-h --help)'{-h,--help}'[show help]' \
    '(-l --list)'{-l,--list}'[list command names]' \
    '(-V --version)'{-V,--version}'[show version]' \
    '(-y --yes)'{-y,--yes}'[skip confirmation prompt]' \
    '1: :->cmd' \
    '*:: :->args' \
    && return 0

  case $state in
    cmd)
      _describe -t commands 'yard command' cmds
      ;;
    args)
      case ${words[1]} in
        up) _arguments '--rebuild[rebuild the env image]' '--yes[skip prompt]' '*:project:_yard_code_target' ;;
        down|info) _arguments '--yes[skip prompt]' '*:project:_yard_code_target' ;;
        remove) _arguments '--purge[also delete yard copy]' '--yes[skip prompt]' '*:project:_files -/' ;;
        sync|bind)
          if [[ ${words[CURRENT-1]} == --target ]]; then
            local -a tg; tg=( yard ${(f)"$(_yard_profiles)"} )
            _describe -t targets 'target' tg
          else
            _arguments '--target[where it runs: yard or a profile]:target:->tgt' '--yes[skip prompt]' '*:project:_files -/'
          fi
          ;;
        export) _arguments '--yes[skip prompt]' '*:project:_files -/' ;;
        emu)
          if (( CURRENT == 2 )); then
            local -a sub; sub=( 'up:boot the emulator in the yard' 'stop:stop the in-yard emulator' 'status:emulator + bridge state' 'adb:bridge emulator adb to host loopback' 'view:scrcpy the emulator screen' 'tunnel:ssh -L fallback bridge' 'down:remove the proxy device' )
            _describe -t subcommands 'emu subcommand' sub
          elif [[ ${words[2]} == view ]]; then
            _arguments '--no-control[view-only (look but do not touch)]' '--view-only[alias of --no-control]' '--control[interactive (default)]' '--yes[skip prompt]'
          else
            _arguments '--yes[skip prompt]'
          fi
          ;;
        code) _arguments '--yes[skip prompt]' '*:project:_yard_code_target' ;;
        status) _arguments '--space[also print on-host size of ~/.subyard]' '--yes[skip prompt]' '--help[show help]' ;;
        teardown|uninstall) _arguments '--keep-data[preserve /srv]' '--yes[skip prompt]' ;;
        clone)
          if [[ ${words[CURRENT-1]} == --target ]]; then
            local -a tg; tg=( yard ${(f)"$(_yard_profiles)"} )
            _describe -t targets 'target' tg
          else
            _arguments '--target[where it runs: yard or a profile]:target:->tgt' '--yes[skip prompt]' '*: :_message "repository URL"'
          fi
          ;;
        *) _arguments '--yes[skip prompt]' '--help[show help]' ;;
      esac
      ;;
  esac
}

# Register. Works whether this file is autoloaded on $fpath or sourced from
# .zshrc. When sourced before compinit ran, bootstrap it so compdef exists.
if (( ! $+functions[compdef] )); then
  autoload -Uz compinit && compinit
fi
compdef _yard yard sy 2>/dev/null
