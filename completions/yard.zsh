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

_yard() {
  local -a cmds
  cmds=( ${(f)"$(yard --list 2>/dev/null)"} )
  [[ -n $cmds ]] || cmds=( setup uninstall check import sync export remove clone code ssh agent list status logs up down )

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
        agent)
          if (( CURRENT == 2 )); then
            _values 'agent subcommand' up shell exec down destroy list
          elif [[ ${words[CURRENT-1]} == --profile ]]; then
            local -a profs; profs=( ${(f)"$(_yard_profiles)"} )
            _describe -t profiles 'profile' profs
          else
            _arguments '--profile[agent profile]:profile:->prof' '--yes[skip prompt]' '*:project:_files -/'
          fi
          ;;
        import) _arguments '--bind[mount instead of copy]' '--yes[skip prompt]' '*:project:_files -/' ;;
        remove) _arguments '--purge[also delete yard copy]' '--yes[skip prompt]' '*:project:_files -/' ;;
        sync|export|code) _arguments '--yes[skip prompt]' '*:project:_files -/' ;;
        uninstall) _arguments '--keep-data[preserve /srv]' '--yes[skip prompt]' ;;
        clone) _message 'repository URL' ;;
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
