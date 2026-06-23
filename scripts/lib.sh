#!/usr/bin/env bash
# lib.sh — shared helpers for Subyard scripts. Source it; do not execute.
# Honors -y/--yes (and ASSUME_YES=1) from the calling script's args.

[ -n "${SUBYARD_LIB_SOURCED:-}" ] && return 0
SUBYARD_LIB_SOURCED=1

# How the caller was invoked (for sudo re-exec): $0/$@ are the caller's here.
SUBYARD_SCRIPT_PATH="$0"
SUBYARD_SCRIPT_ARGV=("$@")

# Config dir (scripts/../config), resolved from lib.sh's own location so it is correct
# regardless of the caller's CWD.
SUBYARD_CONFIG_DIR="${SUBYARD_CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" 2>/dev/null && pwd)}"

# The real operator's home (not root's) even under a sudo re-exec — so config/host.env
# names $SUBYARD_HOME/$SUBYARD_CONFIG_HOME under the operator. Same resolution the root
# scripts use for OPERATOR_USER. Safe under set -e (getent failure → $HOME).
_subyard_operator_home() {
  local u="${SUBYARD_USER:-${SUDO_USER:-${USER:-}}}" h=
  if [ -n "$u" ]; then h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"; fi
  printf '%s\n' "${h:-$HOME}"
}

# load_config — source the layered config files in order, once per process. Each file
# owns distinct keys and uses ${VAR:-…}/:= so an env override always wins. host.env names
# every real host path (see config/host.env); incus.project.env is sourced first so
# host.env can follow project values (e.g. HOST_BASE ← RESTRICTED_DISK_PATHS). Called
# automatically when lib.sh is sourced — scripts never invoke it themselves.
load_config() {
  [ -n "${SUBYARD_CONFIG_LOADED:-}" ] && return 0
  SUBYARD_CONFIG_LOADED=1
  : "${SUBYARD_OPERATOR_HOME:=$(_subyard_operator_home)}"
  local f
  for f in incus.project.env subyard.env host.env; do
    # shellcheck disable=SC1090
    [ -r "$SUBYARD_CONFIG_DIR/$f" ] && . "$SUBYARD_CONFIG_DIR/$f"
  done
}

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

# Load layered config now, so every script that sources lib.sh has config (and host paths)
# available with no boilerplate. -h already exited above (help needs no config).
load_config

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

# incus_preflight [cmd] — die early with an ACCURATE message when the Incus CLI can't
# be used. The old per-script "instance missing / not running — run setup" checks ran
# `incus …` blind: when the daemon is merely unreachable (usual cause: this shell
# predates the incus-admin group granted at setup) they misreported a healthy yard as
# missing and sent the operator to re-run setup. Distinguish the three real states:
#   incus absent              → run 'yard init'
#   unreachable, in group db  → stale group session; use a fresh one (nothing is broken)
#   unreachable, not in group → setup unfinished / group not granted → run 'yard init'
# Returns 0 once incusd answers; callers then probe the instance/state themselves, so a
# genuine "missing"/"not running" only surfaces when the daemon is actually reachable.
incus_preflight() {
  local cmd="${1:-<command>}"
  command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard init' first"
  incus info >/dev/null 2>&1 && return 0
  if id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; then
    warn "can't reach incusd — this shell predates the 'incus-admin' group (the yard is fine)."
    printf '  Run it in a fresh group session:  %ssg incus-admin -c '\''yard %s'\''%s\n' "$C_HEAD" "$cmd" "$C_OFF" >&2
    printf '  (or: newgrp incus-admin, then re-run — log out/in to make it permanent)\n' >&2
    exit 1
  fi
  die "can't reach incusd — Incus isn't installed/running, or you're not in 'incus-admin'. Run 'yard init' first."
}

# nm_unmanaged_guard <bridge> — stop NetworkManager from managing Incus's bridge and
# ANY container/VM veth/tap device. Otherwise NM runs a DHCP client on a yard veth,
# takes a lease from the yard's dnsmasq, and installs a rogue low-metric default route
# that HIJACKS the host's internet. Root; idempotent; no-op when NM is absent/inactive.
nm_unmanaged_guard() {
  # Filename must sort AFTER distro drop-ins: Ubuntu's ubuntu-system-adjustments.conf
  # sets `unmanaged-devices=none` and, read last, would override ours. 'zz-' wins.
  # Belt-and-suspenders: independent [device] match (managed=0) + no-auto-default.
  local bridge="${1:-incusbr0}" conf=/etc/NetworkManager/conf.d/zz-subyard-unmanaged.conf want
  if ! command -v nmcli >/dev/null 2>&1 || ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    ok "NetworkManager not active — no route-hijack guard needed"; return 0
  fi
  rm -f /etc/NetworkManager/conf.d/99-subyard-unmanaged.conf 2>/dev/null  # remove the old, overridden name
  # Match by type/driver AND name: an orphaned veth (e.g. left by a crashed instance)
  # can lose its 'veth*' name but is still type veth. Also cover docker/libvirt bridges
  # (Docker's own docs ask NM to ignore them). ';' list for keyfile, ',' for match-device.
  local spec="type:veth;driver:veth;interface-name:veth*;interface-name:$bridge;interface-name:docker*;interface-name:br-*;interface-name:virbr*;interface-name:vnet*;interface-name:tap*;interface-name:macvtap*"
  local mspec="type:veth,driver:veth,interface-name:veth*,interface-name:$bridge,interface-name:docker*,interface-name:br-*,interface-name:virbr*,interface-name:vnet*,interface-name:tap*,interface-name:macvtap*"
  want="[main]
no-auto-default=$spec

[keyfile]
unmanaged-devices=$spec

[device-subyard]
match-device=$mspec
managed=0"
  if [ ! -f "$conf" ] || ! printf '%s\n' "$want" | cmp -s - "$conf"; then
    printf '%s\n' "$want" > "$conf"
    systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || true
    ok "NetworkManager set to ignore $bridge + veth/tap/docker/virbr ($conf)"
  else
    ok "NetworkManager already ignoring $bridge + veth/tap/docker/virbr"
  fi
  # Verify the EFFECTIVE merged config — a later drop-in overriding ours is exactly the
  # bug that bit us once (silent). Turn that failure mode into a visible warning.
  if command -v NetworkManager >/dev/null 2>&1; then
    if NetworkManager --print-config 2>/dev/null | grep -E '^[[:space:]]*unmanaged-devices' | grep -q 'veth'; then
      ok "verified: NM effective config marks veth unmanaged"
    else
      warn "NM effective config does NOT mark veth unmanaged — another drop-in may override $conf (check: sudo NetworkManager --print-config)"
    fi
  fi
}
