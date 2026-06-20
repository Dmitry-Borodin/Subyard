#!/usr/bin/env bash
#
# lib.sh — shared helpers for Subyard scripts. Source it; do not execute.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib.sh"
#
# Human-friendly conventions provided here:
#   - colored status lines (info/ok/warn/die);
#   - require_root: a clear message + the exact sudo command, instead of a crash;
#   - announce / announce_confirm: an explicit "this is what I will do" banner
#     before consequential actions, with a y/N gate (skipped by -y / ASSUME_YES);
#   - confirm: a reusable yes/no prompt that auto-yes under -y / ASSUME_YES.
#
# Honors -y/--yes (and ASSUME_YES=1) parsed from the calling script's arguments.

# Guard against double-sourcing.
[ -n "${SUBYARD_LIB_SOURCED:-}" ] && return 0
SUBYARD_LIB_SOURCED=1

# Capture how the caller was invoked (for the sudo hint). At source time $0 is
# the calling script and $* are its arguments.
SUBYARD_SCRIPT_PATH="$0"
SUBYARD_SCRIPT_ARGS="$*"

# --- options -----------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
for _arg in "$@"; do
  case "$_arg" in
    -y | --yes) ASSUME_YES=1 ;;
  esac
done
unset _arg

# --- colors / status ---------------------------------------------------------
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

# --- confirm <prompt> --------------------------------------------------------
# Yes if --yes/ASSUME_YES; otherwise ask on a TTY; otherwise (no TTY) treat as no.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ -t 0 ]; then
    local ans
    read -r -p "  $1 [y/N] " ans
    case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
  fi
  return 1
}

# --- require_root "<why>" ----------------------------------------------------
# If not root, print a friendly message with the exact sudo command, then exit.
require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  local why="${1:-it changes the host system}"
  printf '\n%sThis script needs root:%s %s\n' "$C_WARN" "$C_OFF" "$why" >&2
  printf '  Re-run with sudo:\n    %ssudo %s %s%s\n\n' \
    "$C_HEAD" "$SUBYARD_SCRIPT_PATH" "$SUBYARD_SCRIPT_ARGS" "$C_OFF" >&2
  exit 1
}

# --- announce "<title>" "<line>"... ------------------------------------------
# Print an explicit banner of what the script is about to do.
announce() {
  local title="$1"; shift
  printf '\n%s%s%s\n' "$C_HEAD" "$title" "$C_OFF"
  printf '%sThis will:%s\n' "$C_HEAD" "$C_OFF"
  local line
  for line in "$@"; do printf '  • %s\n' "$line"; done
  printf '\n'
}

# --- announce_confirm "<title>" "<line>"... ----------------------------------
# Same banner, then a y/N gate (auto-yes under -y/ASSUME_YES). Use for scripts
# that change the host system, filesystem, or pull/install software.
announce_confirm() {
  announce "$@"
  confirm "Proceed?" || die "aborted by user (pass --yes to skip this prompt)"
}
