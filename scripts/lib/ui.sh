#!/usr/bin/env bash
# ui.sh — CLI help, diagnostics, confirmation and elevation UX.

[ -n "${SUBYARD_UI_SOURCED:-}" ] && return 0
SUBYARD_UI_SOURCED=1

subyard_help_and_exit() {
  awk 'NR==1{next} /^#/{sub(/^#[ ]?/,""); print; next} {exit}' "$SUBYARD_SCRIPT_PATH"
  exit 0
}

ASSUME_YES="${ASSUME_YES:-0}"
for _subyard_arg in "$@"; do
  case "$_subyard_arg" in
    --) break ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help) [ "${SUBYARD_CUSTOM_HELP:-0}" = 1 ] || subyard_help_and_exit ;;
  esac
done
unset _subyard_arg

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_HEAD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_HEAD=''; C_OFF=''
fi

info() { printf '  %s[ .. ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
ok() { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die() { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local question="$1" default="${2:-n}" answer hint
  case "$default" in [yY]*) hint='[Y/n]' ;; *) hint='[y/N]' ;; esac
  if [ -t 0 ]; then
    read -r -p "  $question $hint " answer
    [ -n "$answer" ] || answer="$default"
    case "$answer" in [yY] | [yY][eE][sS]) return 0 ;; esac
  fi
  return 1
}

announce() {
  [ "${SUBYARD_ELEVATED:-0}" = 1 ] && return 0
  local title="$1" line; shift
  [ -n "${YARD_NAME:-}" ] && title="[yard:$YARD_NAME] $title"
  printf '\n%s%s%s\n%sThis will:%s\n' "$C_HEAD" "$title" "$C_OFF" "$C_HEAD" "$C_OFF"
  for line in "$@"; do printf '  • %s\n' "$line"; done
  printf '\n'
}

# shellcheck disable=SC2120 # lifecycle callers optionally choose default Yes
proceed_or_die() {
  [ "${SUBYARD_ELEVATED:-0}" = 1 ] && return 0
  confirm "Proceed?" "${1:-n}" || die "aborted by user (pass --yes to skip this prompt)"
}

announce_confirm() { announce "$@"; proceed_or_die; }
