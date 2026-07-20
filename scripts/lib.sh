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
# host.env can follow project values (e.g. HOST_BASE ← RESTRICTED_DISK_PATHS). agents.env is
# the per-coding-agent layer (default configs + per-agent persist; composes HOST_LINKS) and
# comes after host.env so it can use the mount paths. ports.env names the host loopback
# ports Subyard exposes via Incus proxy devices (e.g. the emulator adb bridge). Called
# automatically when lib.sh is sourced — scripts never invoke it themselves.
#
# Specificity (highest wins): env override > yard context > private/config.env > config
# defaults. Every file uses ${VAR:-…}/:= (or plain assignment for the overlays), so an
# earlier-sourced value survives a later ${VAR:-…} — we source most-specific first:
#   1. the private overlay (../private/config.env) — operator-specific GLOBALS like DEV_SUDO=1.
#   2. the yard context (_load_yard_context) — the selected yard's env file + name-derived
#      defaults. The overlay is sourced BEFORE the context so a per-yard SSH_PORT beats a global
#      one in private/config.env (otherwise a plain overlay assignment would collapse every named
#      yard onto one port). Empty/'default' → a no-op; single-yard behavior stays identical.
#   3. the config/*.env defaults — ${VAR:-…}-guarded, so they only fill what is still unset.
load_config() {
  [ -n "${SUBYARD_CONFIG_LOADED:-}" ] && return 0
  SUBYARD_CONFIG_LOADED=1
  : "${SUBYARD_OPERATOR_HOME:=$(_subyard_operator_home)}"
  # shellcheck disable=SC1091
  [ -r "$SUBYARD_CONFIG_DIR/../private/config.env" ] && . "$SUBYARD_CONFIG_DIR/../private/config.env"
  _load_yard_context
  local f
  for f in incus.project.env subyard.env host.env agents.env ports.env; do
    # shellcheck disable=SC1090
    [ -r "$SUBYARD_CONFIG_DIR/$f" ] && . "$SUBYARD_CONFIG_DIR/$f"
  done
  # Explicit success: each `[ -r … ] && .` (the overlay above and the loop) returns 1 when the
  # file is absent, and load_config runs while the caller's `set -e` is active — so without this,
  # a checkout missing the last-sourced file (e.g. no ports.env, or no gitignored private/config.env)
  # makes load_config → 1 and EVERY `yard` command dies silently at exit 1. Never let this
  # function's status ride on any single file's presence.
  return 0
}

# --- Yard registry + context (multi-yard) ------------------------------------
# A "yard context" is a per-yard env file sourced FIRST by load_config, whose values (and the
# name-derived defaults below) win over the generic config/*.env layers. Works WITHOUT incus and
# WITHOUT a loaded context — the dispatcher, `yard yards` and cross-yard resolution use the
# registry helpers before any yard is selected.

# yard_registry_dirs — the two dirs that hold per-yard env files, in precedence order:
# the private overlay repo first, the machine-local config home second. Non-existent dirs
# are still printed (callers guard on -d/-r); this only names WHERE to look.
yard_registry_dirs() {
  : "${SUBYARD_OPERATOR_HOME:=$(_subyard_operator_home)}"
  printf '%s\n' "$SUBYARD_CONFIG_DIR/../private/yards"
  printf '%s\n' "${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}/yards"
}

# yard_env_file <name> — path to a yard's context env file (first match wins, private
# overlay before machine-local). Prints the path and returns 0, or returns 1 if none.
yard_env_file() {
  local name="${1:?yard_env_file needs a name}" d
  while IFS= read -r d; do
    [ -r "$d/$name.env" ] && { printf '%s\n' "$d/$name.env"; return 0; }
  done < <(yard_registry_dirs)
  return 1
}

# yard_registry_names — 'default' plus the basename of every *.env in the registry dirs,
# deduped (private overlay wins because it is listed first). One name per line.
yard_registry_names() {
  local d f
  {
    printf 'default\n'
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      for f in "$d"/*.env; do
        [ -e "$f" ] || continue
        basename "$f" .env
      done
    done < <(yard_registry_dirs)
  } | awk 'NF && !seen[$0]++'
}

# _yard_valid_name <name> — the allowed context name shape: [a-z0-9][a-z0-9_-]*.
_yard_valid_name() {
  case "$1" in
    '' | *[!a-z0-9_-]*) return 1 ;;
    [a-z0-9]*)          return 0 ;;
    *)                  return 1 ;;
  esac
}

# remote_hostkey_alias <context-name> — the stable OpenSSH host-key namespace for a remote
# context. Keep this derived from the already-restricted context name only: owner-host aliases,
# ports and other private/mutable values must never become part of the trust identity (or SSH
# config syntax). Prints nothing and returns 1 for an invalid name.
remote_hostkey_alias() {
  local name="${1:-}"
  _yard_valid_name "$name" || return 1
  printf 'subyard-remote-%s' "$name"
}

# remote_add_hint <context-name> <dest> <remote-yard> — reproduce the exact mapping for an
# idempotent refresh. The optional owner-host yard must not disappear from repair diagnostics.
remote_add_hint() {
  printf '%s remote add %s %s' "${PROG:-yard}" "$1" "$2"
  [ -n "${3:-}" ] && printf ' --yard %s' "$3"
  return 0
}

# _yard_apply_derivations <name> — after a yard's env file is sourced, fill the name-derived
# defaults for anything it did NOT set (env-override-wins). Shared by load_config's context
# step and read-only consumers (`yard yards`). Does not source the file and does not die.
_yard_apply_derivations() {
  local name="$1" cfg_home="${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}"
  YARD_NAME="$name"
  : "${INSTANCE_NAME:=yard-$name}"
  : "${INCUS_PROJECT:=subyard-$name}"
  : "${SSH_HOST:=yard-$name}"
  : "${SRV_VOLUME:=yard-srv-$name}"
  : "${RESTRICTED_DISK_PATHS:=/srv/subyard-$name}"
  # Per-yard machine-local project state; the default yard keeps $SUBYARD_CONFIG_HOME/projects
  # (lib-state.sh: STATE_DIR="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}").
  : "${SUBYARD_STATE_DIR:=$cfg_home/yards/$name/projects}"
}

# _load_yard_context — called by load_config BEFORE the config/*.env layers. Resolves
# $SUBYARD_YARD: empty or 'default' → no-op. Otherwise validate the name, source the yard's env
# file (die listing known yards if absent), then apply the name-derived defaults. A local yard
# MUST declare SSH_PORT (the one thing we cannot guess without risking a host-port collision);
# a remote yard carries YARD_TYPE=remote.
_load_yard_context() {
  local name="${SUBYARD_YARD:-}"
  case "$name" in '' | default) return 0 ;; esac
  _yard_valid_name "$name" \
    || die "invalid yard name '$name' (allowed: lowercase letters, digits, '-', '_'; must start with a letter or digit)"
  local f
  f="$(yard_env_file "$name")" \
    || die "unknown yard '$name' — known yards: $(yard_registry_names | tr '\n' ' ')"
  # shellcheck disable=SC1090
  . "$f"
  _yard_apply_derivations "$name"
  if [ "${YARD_TYPE:-local}" != remote ] && [ -z "${SSH_PORT:-}" ]; then
    die "yard '$name' ($f) sets no SSH_PORT — a local yard needs a unique host loopback port (add e.g. SSH_PORT=2223)"
  fi
  return 0
}

# yard_cmd_hint — the CLI prefix that reproduces the ACTIVE context in a copy-pasteable
# hint: 'yard' for the default yard, 'yard -Y <name>' inside a named context. Lets scripts
# print next-step hints that stay in the current yard (e.g. "run: $(yard_cmd_hint) sync .").
yard_cmd_hint() {
  printf '%s' "${PROG:-yard}"
  [ -n "${YARD_NAME:-}" ] && printf ' -Y %s' "$YARD_NAME"
  # Explicit success: the trailing `[ -n … ] && printf` returns 1 for the default yard (empty
  # YARD_NAME), and this runs inside a `h="$(yard_cmd_hint)"` under the caller's `set -e` — so
  # without this a default-yard call aborts the caller mid-output (e.g. `yard init` right after
  # "Subyard is up."). Never let this function's status ride on the YARD_NAME test.
  return 0
}

# --- shared pure helpers -----------------------------------------------------
# Small, dependency-free readers/formatters with a single canonical home here — several scripts
# (yard-remote.sh, yard-yards.sh, yard-ctl.sh, lib-state.sh) call these instead of keeping copies.

# yard_env_val <file> <KEY> — value of a simple `KEY=value` line (last wins, quotes stripped,
# indentation tolerated). A targeted read — never sources the file. Missing file/key → empty,
# returns 0 (safe under `set -e`). The dispatcher keeps its own twin (bin/yard:_yard_env_val).
yard_env_val() {
  sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# json_str/json_num <json> <key> — scrape one field from the flat one-line JSON that `yard _info`
# (and the yard meta) emit. No jq: a string value ("k":"v") or a bare number ("k":n).
json_str() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -n1; }
json_num() { sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" <<<"$1" | head -n1; }

# age_human <seconds> — compact duration: 45s / 12m / 3h / 2d.
age_human() {
  local s="$1"
  if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi
}

# remote_cache_path <name> — the last-good `_info` probe cache for a remote yard (line 1 = epoch,
# line 2 = the _info JSON). Shared by yard-remote.sh / yard-yards.sh / yard-ctl.sh.
remote_cache_path() { printf '%s/remote-%s.cache\n' "$SUBYARD_HOME" "$1"; }

# remote_info_keep_cached_projects <live-json> <cache-file> — `_info` deliberately reports
# projects:null when the owner host cannot read the live yard metadata. Preserve the last
# successfully observed numeric count in that case while keeping every other field (notably the
# current state) from the fresh probe. With no previous count the null stays null and callers show
# '-'; a failed observation must never turn into the misleading number zero.
remote_info_keep_cached_projects() {
  local json="$1" cache="$2" projects cached
  projects="$(json_num "$json" projects)"
  if [ -n "$projects" ] || [ ! -f "$cache" ]; then
    printf '%s\n' "$json"
    return 0
  fi
  cached="$(sed -n '2p' "$cache" 2>/dev/null)"
  projects="$(json_num "$cached" projects)"
  if [ -z "$projects" ]; then
    printf '%s\n' "$json"
    return 0
  fi
  case "$json" in
    *'"projects":null'*) printf '%s\n' "${json/\"projects\":null/\"projects\":$projects}" ;;
    *)                   printf '%s\n' "$json" ;;
  esac
}

# count_json_files <dir> — number of *.json files in <dir> (0 for a missing/empty dir).
count_json_files() {
  local dir="$1" n=0 f
  [ -d "$dir" ] || { printf '0'; return 0; }
  for f in "$dir"/*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# Pure desired-power + host-route predicates. This library reads no Subyard config itself and is
# also copied into the root-owned boot reconciler, which must never execute the operator checkout.
# shellcheck source=scripts/lib-power.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-power.sh"
# Pure context/path policy is shared by config loading, bind and security-lint.
# shellcheck source=scripts/lib-context.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-context.sh"

# state_dir_for_yard <name> — machine-local project state dir for ANY yard, derived like
# SUBYARD_STATE_DIR: the default yard keeps the flat projects/ dir; a named yard lives under
# yards/<name>/projects. Pure path helper — lives here so both lib-state.sh and yard-remote.sh
# (which does not source lib-state) can use it.
state_dir_for_yard() {
  local name="${1:?state_dir_for_yard needs a name}"
  local cfg_home="${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}"
  case "$name" in
    '' | default) printf '%s/projects\n' "$cfg_home" ;;
    *)            printf '%s/yards/%s/projects\n' "$cfg_home" "$name" ;;
  esac
}

# -h/--help on any script prints its header comment block and exits.
_yard_help_and_exit() {
  awk 'NR==1{next} /^#/{sub(/^#[ ]?/,""); print; next} {exit}' "$SUBYARD_SCRIPT_PATH"
  exit 0
}
ASSUME_YES="${ASSUME_YES:-0}"
for _arg in "$@"; do
  case "$_arg" in
    --)           break ;;
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

# confirm "<question>" [y|n] — ask a yes/no question.
#   $2 sets which answer a bare Enter takes: "n" (default) shows [y/N]; "y" shows [Y/n].
# Yes under -y/ASSUME_YES; else ask on a TTY (an empty reply takes the default); else no
# (a non-interactive run without --yes always refuses, whatever the default).
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local q="$1" def="${2:-n}" ans hint
  case "$def" in [yY]*) hint='[Y/n]' ;; *) hint='[y/N]' ;; esac
  if [ -t 0 ]; then
    read -r -p "  $q $hint " ans
    [ -n "$ans" ] || ans="$def"
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
    # sudo scrubs the environment — carry the yard context (and operator home) through,
    # or the elevated re-run would load the DEFAULT context and mutate the wrong yard.
    exec sudo -- env SUBYARD_ELEVATED=1 \
      ${SUBYARD_YARD:+SUBYARD_YARD="$SUBYARD_YARD"} \
      ${SUBYARD_YARD_EXPLICIT:+SUBYARD_YARD_EXPLICIT="$SUBYARD_YARD_EXPLICIT"} \
      "$SUBYARD_SCRIPT_PATH" \
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
  # Carry the active yard into every mutating banner. Default yard: YARD_NAME unset → title
  # unchanged, bit-for-bit as before.
  [ -n "${YARD_NAME:-}" ] && title="[yard:$YARD_NAME] $title"
  printf '\n%s%s%s\n%sThis will:%s\n' "$C_HEAD" "$title" "$C_OFF" "$C_HEAD" "$C_OFF"
  local line
  for line in "$@"; do printf '  • %s\n' "$line"; done
  printf '\n'
}

# Proceed gate — nothing mutating runs before it returns. Skipped on the sudo re-run
# (already answered before elevation). The default answer encodes how reversible the
# action is:
#   proceed_or_die       default No  (y/N) — durable/settings changes: install, mount,
#                                     provision, network, git identity, destroy, remove,
#                                     teardown. The operator must opt in explicitly.
#   proceed_or_die y     default Yes (Y/n) — transient, reversible lifecycle actions:
#                                     bring a shared resource up/down, start/stop a
#                                     service. A bare Enter proceeds.
proceed_or_die() {
  [ "${SUBYARD_ELEVATED:-0}" = 1 ] && return 0
  confirm "Proceed?" "${1:-n}" || die "aborted by user (pass --yes to skip this prompt)"
}

# Banner + gate for non-root mutating scripts. Root scripts use:
# announce ... ; require_root ... ; proceed_or_die.
announce_confirm() {
  announce "$@"
  proceed_or_die
}

# incus_preflight — the single gate every incus-using script calls before talking to the
# daemon. Returns 0 once incusd answers (callers then probe the instance themselves); else
# dies with the accurate cause:
#   incus absent                  → run 'yard init'
#   unreachable, in incus-admin   → this session predates the group → log back in
#   unreachable, not in group     → group not granted / daemon down → run 'yard init'
incus_preflight() {
  command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard init' first"
  incus info >/dev/null 2>&1 && return 0
  if id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; then
    warn "can't reach the Incus daemon: this session predates your 'incus-admin' group (the yard is fine)."
    printf "  Log out and back in once to fix it everywhere, or run %snewgrp incus-admin%s for this shell.\n" "$C_HEAD" "$C_OFF" >&2
    exit 1
  fi
  die "can't reach Incus — you're not in the 'incus-admin' group, or the daemon isn't running. Run 'yard init' first."
}

# nm_unmanaged_guard <bridge> — stop NetworkManager from managing Incus's bridge and
# ANY container/VM veth/tap device. Otherwise NM runs a DHCP client on a yard veth,
# takes a lease from the yard's dnsmasq, and installs a rogue low-metric default route
# that HIJACKS the host's internet. Root; idempotent; no-op when NM is absent/inactive.
nm_unmanaged_guard() {
  # Filename must sort AFTER distro drop-ins: Ubuntu's ubuntu-system-adjustments.conf
  # sets `unmanaged-devices=none` and, read last, would override ours. 'zz-' wins.
  # Belt-and-suspenders: independent [device] match (managed=0) + no-auto-default.
  local bridge="${1:-incusbr0}" conf="${2:-/etc/NetworkManager/conf.d/zz-subyard-unmanaged.conf}"
  local want changed=0 nm_rc
  if power_nm_active; then :; else
    nm_rc=$?
    if [ "$nm_rc" -eq 1 ]; then
      ok "NetworkManager not active — no route-hijack guard needed"; return 0
    fi
    die "$POWER_ERROR"
  fi
  install -d -m 0755 "$(dirname "$conf")"
  rm -f "$(dirname "$conf")/99-subyard-unmanaged.conf" 2>/dev/null
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
    changed=1
  fi
  chmod 0644 "$conf"
  systemctl reload NetworkManager 2>/dev/null \
    || { command -v nmcli >/dev/null 2>&1 && nmcli general reload 2>/dev/null; } \
    || die "could not reload NetworkManager after updating $conf"
  if [ "$changed" = 1 ]; then
    ok "NetworkManager set to ignore $bridge + veth/tap/docker/virbr ($conf)"
  else
    ok "NetworkManager already ignoring $bridge + veth/tap/docker/virbr"
  fi
  # Verify the EFFECTIVE merged config — a later drop-in overriding ours is exactly the bug that
  # bit us once. This is a hard safety gate: no yard start may proceed with an ineffective guard.
  power_nm_guard_effective "$bridge" \
    || die "$POWER_ERROR (check: sudo NetworkManager --print-config)"
  ok "verified: NM effective config protects $bridge and veth devices"
}

# ufw_yard_rules_present <bridge> — prove the persisted UFW rules without sudo. UFW itself is
# root-only and stores its rules as 0640 root:root, so 06-network.sh grants the already
# root-equivalent incus-admin group read access after applying them. Parse UFW's stable tuple
# records rather than localized `ufw status` output.
ufw_yard_rules_present() {
  local bridge="${1:?ufw_yard_rules_present needs a bridge}"
  local rules="${SUBYARD_UFW_RULES_FILE:-/etc/ufw/user.rules}"
  [ -r "$rules" ] || return 1
  awk -v bridge="$bridge" '
    $1 == "###" && $2 == "tuple" && $3 == "###" {
      action = $4; dport = $6; iface = $10
      if (action == "allow" && dport == "67" && iface == "in_" bridge) dhcp = 1
      if (action == "allow" && dport == "53" && iface == "in_" bridge) dns = 1
      if (action == "route:allow" && iface == "in_" bridge) route_in = 1
      if (action == "route:allow" && iface == "out_" bridge) route_out = 1
    }
    END { exit !(dhcp && dns && route_in && route_out) }
  ' "$rules"
}

ufw_rules_set_probe_access() { # <enable|disable>
  local mode="${1:?ufw_rules_set_probe_access needs enable or disable}"
  local rules="${SUBYARD_UFW_RULES_FILE:-/etc/ufw/user.rules}" group
  [ -e "$rules" ] || return 1
  case "$mode" in
    enable) group=incus-admin; getent group "$group" >/dev/null 2>&1 || return 1 ;;
    disable) group=root ;;
    *) return 2 ;;
  esac
  chgrp "$group" "$rules" && chmod 0640 "$rules"
}

# zabbly_suite — echo the apt suite (distro codename) for the Zabbly repo, or fail (non-apt /
# no codename). Ubuntu derivatives (e.g. Linux Mint) MUST use UBUNTU_CODENAME — Zabbly has no
# Mint suites, only the upstream Ubuntu/Debian ones.
zabbly_suite() {
  command -v apt-get >/dev/null 2>&1 || return 1
  [ -r /etc/os-release ] || return 1
  local suite
  suite="$( . /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" )"
  [ -n "$suite" ] || return 1
  printf '%s\n' "$suite"
}

# add_zabbly_lts_repo — root, idempotent. Install the Zabbly LTS-6.0 keyring + apt source so
# 'incus' >= 6.0.6 is installable on Debian/Ubuntu (and derivatives). Returns non-zero (without
# dying) if the repo can't be set up — no apt, unknown codename, missing curl, or a failed
# download/update — so callers can fall back to the distro package.
add_zabbly_lts_repo() {
  local key=/etc/apt/keyrings/zabbly.asc
  local src=/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources
  local suite arch want
  suite="$(zabbly_suite)" || { warn "no apt codename in /etc/os-release — can't add the Zabbly repo"; return 1; }
  command -v curl >/dev/null 2>&1 || { warn "curl not found — can't fetch the Zabbly signing key"; return 1; }
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -s "$key" ]; then
    curl -fsSL https://pkgs.zabbly.com/key.asc -o "$key" \
      || { warn "failed to download the Zabbly signing key"; return 1; }
    chmod 0644 "$key"
    ok "installed Zabbly signing key ($key)"
  else
    ok "Zabbly signing key already present"
  fi
  want="Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-6.0
Suites: $suite
Components: main
Architectures: $arch
Signed-By: $key"
  if [ ! -f "$src" ] || ! printf '%s\n' "$want" | cmp -s - "$src"; then
    printf '%s\n' "$want" > "$src"
    ok "added Zabbly LTS-6.0 apt source ($src; suite=$suite)"
  else
    ok "Zabbly LTS-6.0 apt source already present (suite=$suite)"
  fi
  info "apt-get update (Zabbly)"
  apt-get update -qq || { warn "apt-get update failed after adding the Zabbly repo"; return 1; }
  return 0
}

# Load layered config now, so every script that sources lib.sh has config (and host paths)
# available with no boilerplate. Runs LAST in this file — after die()/colors are defined —
# because the yard-context step (_load_yard_context) may die on a bad -Y name/missing port.
# -h already exited above (help needs no config).
load_config
context_validate || die "invalid Subyard context: $CONTEXT_ERROR"
