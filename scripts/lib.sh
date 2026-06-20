#!/usr/bin/env bash
# lib.sh — shared helpers for Subyard scripts. Source it; do not execute.
# Honors -y/--yes (and ASSUME_YES=1) from the calling script's args.

[ -n "${SUBYARD_LIB_SOURCED:-}" ] && return 0
SUBYARD_LIB_SOURCED=1

# How the caller was invoked (for sudo re-exec): $0/$@ are the caller's here.
SUBYARD_SCRIPT_PATH="$0"
SUBYARD_SCRIPT_ARGV=("$@")

# -h/--help on any script prints its header comment block and exits.
_yard_help_and_exit() {
  awk 'NR==1{next} /^#/{sub(/^#[ ]?/,""); print; next} {exit}' "$SUBYARD_SCRIPT_PATH"
  exit 0
}
ASSUME_YES="${ASSUME_YES:-0}"
for _arg in "$@"; do
  case "$_arg" in
    -y | --yes)  ASSUME_YES=1 ;;
    -h | --help) _yard_help_and_exit ;;
  esac
done
unset _arg

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'
  C_HEAD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_HEAD=''; C_OFF=''
fi
info() { printf '  %s[ .. ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# Yes under -y/ASSUME_YES; else ask on a TTY; else no.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ -t 0 ]; then
    local ans
    read -r -p "  $1 [y/N] " ans
    case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
  fi
  return 1
}

# require_root "<why>" — call AFTER announce + proceed_or_die (user already agreed).
# Not root → re-exec self under sudo by absolute path (sudo drops ~/.local/bin from
# PATH, so `sudo yard` fails). The elevated re-run skips banner+prompt (already
# shown/answered) via SUBYARD_ELEVATED, then does the work.
require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  local why="${1:-it changes the host system}"
  if command -v sudo >/dev/null 2>&1; then
    warn "this needs root: $why"
    info "re-running under sudo (you'll be asked for your password)…"
    exec sudo -- env SUBYARD_ELEVATED=1 "$SUBYARD_SCRIPT_PATH" \
      ${SUBYARD_SCRIPT_ARGV[@]+"${SUBYARD_SCRIPT_ARGV[@]}"}
  fi
  printf '\n%sNeeds root and sudo is not installed — run as root:%s\n    %s%s %s%s\n\n' \
    "$C_WARN" "$C_OFF" "$C_HEAD" "$SUBYARD_SCRIPT_PATH" "${SUBYARD_SCRIPT_ARGV[*]:-}" "$C_OFF" >&2
  exit 1
}

# Banner of what the script will do. Skipped on a sudo re-run.
announce() {
  [ "${SUBYARD_ELEVATED:-0}" = 1 ] && return 0
  local title="$1"; shift
  printf '\n%s%s%s\n%sThis will:%s\n' "$C_HEAD" "$title" "$C_OFF" "$C_HEAD" "$C_OFF"
  local line
  for line in "$@"; do printf '  • %s\n' "$line"; done
  printf '\n'
}

# y/N gate (default N) — nothing mutating runs before it returns. Skipped on the
# sudo re-run (already answered before elevation).
proceed_or_die() {
  [ "${SUBYARD_ELEVATED:-0}" = 1 ] && return 0
  confirm "Proceed?" || die "aborted by user (pass --yes to skip this prompt)"
}

# Banner + gate for non-root mutating scripts. Root scripts use:
# announce ... ; require_root ... ; proceed_or_die.
announce_confirm() {
  announce "$@"
  proceed_or_die
}
