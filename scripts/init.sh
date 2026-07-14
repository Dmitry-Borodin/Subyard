#!/usr/bin/env bash
# init.sh — one-shot yard bring-up (`yard init`).
#
# Runs the whole pipeline end-to-end and idempotently: host preflight → install
# Incus → project → instance → network → mounts → provision → ssh → git identity
# → project extras. A re-run reconciles drift and skips finished steps; it is
# conservative and may miss a content-only change (`--configs` refreshes agent dotfiles;
# `--reset` remains the full destructive re-apply).
#
# Installing Incus moves you into the 'incus-admin' group, which only takes effect
# in a fresh session. Rather than stop and make you re-run, init re-execs itself
# under a fresh group session ('sg') so a single 'yard init' completes start to end.
#
# Usage: yard init [--configs | --reset] [-y]
#   yard init --configs   Refresh global agent instructions and default configs only; no rebuild.
#   yard init --reset     Tear down the yard, then a fresh init — force-apply a config change
#                         the conservative reconcile didn't pick up. Asks before anything.
#   -y, --yes             Skip the confirmation prompt (automation/CI).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")   # preserved so we can re-exec ourselves under a fresh group session
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# ============================================================================
# Configuration — the names the probes and steps below reference.
# ============================================================================
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INCUS_BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
STORAGE_POOL="${STORAGE_POOL:-default}"
PROJ=(--project "$INCUS_PROJECT")
MIN_INCUS_VER="${MIN_INCUS_VER:-6.0.6}"   # nested-Docker floor; see 00-check-host.sh

# ============================================================================
# Read-only state probes — no side effects; they decide what THIS run will do.
# ============================================================================

# -- Incus presence & version ------------------------------------------------
reachable()     { command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; }
incus_present() { command -v incus >/dev/null 2>&1; }
incus_recent()  { local v; v="$(incus --version 2>/dev/null || echo '?')"
                  [ "$v" != '?' ] && command -v dpkg >/dev/null 2>&1 \
                    && dpkg --compare-versions "$v" ge "$MIN_INCUS_VER"; }
incus_too_old() { incus_present && ! incus_recent; }

# apt's candidate Incus is too old (or unknown) → a fresh distro install misses the floor.
distro_incus_too_old() {
  command -v apt-get   >/dev/null 2>&1 || return 1   # not apt-based: no Zabbly path to offer
  command -v apt-cache >/dev/null 2>&1 || return 0   # apt but no cache info: assume too old
  local c; c="$(apt-cache policy incus 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  { [ -n "$c" ] && [ "$c" != '(none)' ] && command -v dpkg >/dev/null 2>&1 \
      && dpkg --compare-versions "$c" ge "$MIN_INCUS_VER"; } && return 1
  return 0
}

# -- Per-step "already done?" tests (drive the plan's [do]/[skip]) ------------
# 01 counts as done only when the daemon is reachable AND its pool + bridge exist:
# 'yard teardown' drops the pool/bridge but leaves Incus installed, so a bare
# reachability test would wrongly skip re-init and 02 would fail (no incusbr0).
have_init()     { reachable && incus storage show "$STORAGE_POOL" >/dev/null 2>&1 \
                            && incus network show "$INCUS_BRIDGE" >/dev/null 2>&1; }
have_project()  { reachable && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; }
have_instance() { reachable && incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1; }
have_network()  { [ -n "$(reachable && incus list "$INSTANCE_NAME" "${PROJ[@]}" -c4 -fcsv 2>/dev/null)" ]; }

# Every device named in HOST_MOUNTS is attached → adding/removing a mount re-runs 05.
have_mounts() {
  reachable || return 1
  local attached name
  attached=" $(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | tr '\n' ' ') "
  while IFS=: read -r name _; do
    [ -n "$name" ] || continue
    case "$attached" in *" $name "*) ;; *) return 1 ;; esac
  done < <(printf '%s\n' "${HOST_MOUNTS:-}" | sed 's/[[:space:]]//g')
  return 0
}

# Presence-only check of what 04 applies (docker, dev user, global agent instructions, HOST_LINKS, and
# dev sudoers matching DEV_SUDO). PRESENCE only, so it never flip-flops; a content/
# dotfiles refresh is deliberately NOT caught here — use 'yard init --reset' for that.
have_provision() {
  reachable || return 1
  local claude_req=0 codex_agents_req=0
  [ -n "${HOST_CLAUDE_MD:-}" ] && [ -f "$HOST_CLAUDE_MD" ] && claude_req=1
  [ -n "${HOST_CODEX_AGENTS_MD:-}" ] && [ -f "$HOST_CODEX_AGENTS_MD" ] && codex_agents_req=1
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env DEV_USER="${DEV_USER:-dev}" --env DEV_SUDO="${DEV_SUDO:-0}" \
    --env CLAUDE_REQ="$claude_req" --env CODEX_AGENTS_REQ="$codex_agents_req" \
    --env HOST_LINKS="${HOST_LINKS:-}" \
    -- sh -s >/dev/null 2>&1 <<'CHK'
set -eu
command -v docker >/dev/null
id "$DEV_USER" >/dev/null
home="$(getent passwd "$DEV_USER" | cut -d: -f6)"; home="${home:-/home/$DEV_USER}"
if [ "${CLAUDE_REQ:-0}" = 1 ]; then [ -f "$home/.claude/CLAUDE.md" ]; fi
if [ "${CODEX_AGENTS_REQ:-0}" = 1 ]; then [ -f "$home/.codex/AGENTS.md" ]; fi
s="/etc/sudoers.d/90-subyard-$DEV_USER"
if [ "${DEV_SUDO:-0}" = 1 ]; then [ -f "$s" ]; else [ ! -f "$s" ]; fi
drift=0
for e in $(printf '%s\n' "${HOST_LINKS:-}" | sed 's/[[:space:]]//g'); do
  name="${e%%:*}"; rest="${e#*:}"; target="${rest%%:*}"
  { [ -n "$name" ] && [ -n "$target" ]; } || continue
  mroot="/$(printf '%s' "$target" | cut -d/ -f2-4)"
  [ -d "$mroot" ] || continue
  { [ -e "$home/$name" ] || [ -L "$home/$name" ]; } || drift=1
done
[ "$drift" = 0 ]
CHK
}

have_ssh()    { reachable && incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh; }
have_gitid()  { reachable && incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -s "/home/${DEV_USER:-dev}/.gitconfig" >/dev/null 2>&1; }
in_admin_db() { id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; }

# Any on-disk profile declares yard-level extras (YARD_*)? init enables ALL profiles; 09 unions them.
any_yard_extras() {
  local pf
  for pf in "$SCRIPT_DIR/../config/profiles"/*/profile.conf; do
    [ -r "$pf" ] || continue
    # shellcheck disable=SC1090
    ( . "$pf"; [ -n "${YARD_MOUNTS:-}${YARD_CAPS:-}${YARD_DEVICES:-}" ] ) && return 0
  done
  return 1
}
no_yard_extras() { ! any_yard_extras; }

# In-yard projects whose profile ships a provision.sh — drives the opt-in offer below.
provisionable_profiles() {
  command -v jq >/dev/null 2>&1 || return 0
  local sd="$SUBYARD_CONFIG_HOME/projects" f prof
  [ -d "$sd" ] || return 0
  for f in "$sd"/*.json; do
    [ -e "$f" ] || continue
    prof="$(jq -r '.profile // ""' "$f" 2>/dev/null)"; [ -n "$prof" ] || continue
    [ -r "$SCRIPT_DIR/../config/profiles/$prof/provision.sh" ] && printf '%s\n' "$prof"
  done | sort -u || true
  # `|| true`: the for-loop's status is its last iteration's `[ -r … ] && printf`, which is 1 when
  # the last project's profile ships no provision.sh; pipefail would then make this function return
  # 1 and abort its set -e caller (offer_provision, near init's final exit). The names are already
  # on stdout; only the status needs neutralising.
}

# ============================================================================
# Interactive prompts — asked only after the main 'Proceed?' gate.
# ============================================================================

# want_zabbly <install|upgrade> — pull Incus from the Zabbly LTS-6.0 repo? It is the only
# source that meets the nested-Docker floor, so the default is YES; -y / a non-TTY take
# that default automatically. Returns non-zero only on an explicit "no" (or when apt is
# absent, since Zabbly is apt-only and there is nothing to add).
want_zabbly() {
  command -v apt-get >/dev/null 2>&1 || return 1
  { [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; } && return 0
  local ans
  read -r -p "  Add the Zabbly LTS-6.0 apt repo and ${1:-install} Incus (>= $MIN_INCUS_VER) from there? [Y/n] " ans
  case "$ans" in [nN] | [nN][oO]) return 1 ;; *) return 0 ;; esac
}

# Opt-in toolchain provisioning at the end of init — default N, never under -y / non-TTY (heavy).
offer_provision() {
  local profs; profs="$(provisionable_profiles | paste -sd' ' -)"
  if [ -n "$profs" ] && [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    local ans
    read -r -p "  Provision toolchains for [$profs] into the yard now? (heavy) [y/N] " ans
    case "$ans" in
      [yY] | [yY][eE][sS]) "$SCRIPT_DIR/10-provision-profile.sh" --yes ;;
      *) info "skipped — run later:  yard provision" ;;
    esac
  elif [ -n "$profs" ]; then
    printf '  yard provision    # install the in-yard toolchain for: %s (heavy, explicit)\n' "$profs"
  else
    printf '  yard provision -l # list profiles whose toolchain you can install into the yard\n'
  fi
}

# ============================================================================
# Group-session re-exec.
# ============================================================================
# Installing Incus adds you to 'incus-admin', but the group only applies in a fresh
# session, so the daemon stays unreachable in THIS shell. Re-exec the whole init under
# a fresh group session ('sg') so one run completes. Guarded against looping; returns
# non-zero so callers fall back to the manual hint if 'sg' is missing or still can't
# connect. $1=1 → assume-yes in the child (the plan was already confirmed up top); the
# parent's Zabbly answer is carried in SUBYARD_ZABBLY so the unattended child honors an
# explicit "no" instead of silently re-deciding "yes" under assume-yes.
reexec_under_group() {
  [ "${SUBYARD_SG_REEXEC:-0}" = 1 ] && return 1
  command -v sg >/dev/null 2>&1 || return 1
  local q; printf -v q '%q ' "$SCRIPT_DIR/init.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  local pre="SUBYARD_SG_REEXEC=1"
  if [ "${1:-0}" = 1 ]; then
    pre+=" ASSUME_YES=1"
    if [ "${ZB+set}" = set ] && [ "${#ZB[@]}" -gt 0 ]; then pre+=" SUBYARD_ZABBLY=1"; else pre+=" SUBYARD_ZABBLY=0"; fi
  fi
  info "continuing under a fresh 'incus-admin' group session (no manual re-run needed)…"
  exec sg incus-admin -c "$pre exec $q"
}

# ============================================================================
# Plan — the read-only summary of what this run will do.
# ============================================================================
plan_do()   { printf '  %s[do]%s   %s\n' "$C_OK"   "$C_OFF" "$1"; pending=1; }
plan_skip() { printf '  %s[skip]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
step()      { if "$1"; then plan_skip "$2"; else plan_do "$2"; fi; }   # <done-test> <label>

print_plan() {
  pending=0
  printf '\n%sSubyard init — full bring-up%s\n%sThis run will (finished steps are skipped):%s\n' \
    "$C_HEAD" "$C_OFF" "$C_HEAD" "$C_OFF"
  if ! have_init; then
    plan_do   "Install Incus, add you to 'incus-admin', init storage (needs root)"
  elif incus_too_old; then
    plan_do   "Upgrade Incus to >= $MIN_INCUS_VER for nested Docker (needs root)"
  else
    plan_skip "Incus installed, initialized, and >= $MIN_INCUS_VER"
  fi
  step have_project   "Create the Incus project '$INCUS_PROJECT'"
  step have_instance  "Create the yard instance (+ /dev/kvm, /srv volume)"
  step have_network   "Open host DHCP/DNS for the yard bridge (ufw; needs root)"
  step have_mounts    "Create host dirs under $HOST_BASE and mount them (needs root)"
  step have_provision "Provision the yard (packages, Docker, user, services)"
  step have_ssh       "Set up SSH access into the yard (proxy + your key)"
  step have_gitid     "Give the in-yard 'dev' user a git identity (from host/config)"
  step no_yard_extras "Apply yard extras requested by projects (mounts/caps/devices)"
  printf '\n'
}

# ============================================================================
# Steps — the actual bring-up, run only after confirmation.
# ============================================================================

# Read-only host preflight (00). Hard failures abort before anything mutates.
# SUBYARD_PREFLIGHT_STRICT=1 makes a cross-yard SSH_PORT collision a HARD failure here (init
# must not create a second yard on a port another yard already claims); a plain `yard check`
# leaves that check advisory (warn only).
host_preflight() {
  STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME}" SUBYARD_PREFLIGHT_STRICT=1 "$SCRIPT_DIR/00-check-host.sh" \
    || die "host preflight failed — fix the items above, then re-run '$(yard_cmd_hint) init'"
}

# Install Incus on first run (then continue under a fresh group session), or upgrade it
# in place when it is older than the floor. ZB carries the --zabbly choice from main.
incus_install_or_upgrade() {
  if ! have_init; then
    info "→ install / init Incus"
    "$SCRIPT_DIR/01-install-incus.sh" --yes ${ZB[@]+"${ZB[@]}"}
    if ! reachable; then
      echo
      ok "Incus installed and you're added to 'incus-admin'."
      reexec_under_group 1 || true
      cat <<'MSG'

One step needs a fresh group session. Continue with:
    sg incus-admin -c 'yard init'
  (or re-login / run 'newgrp incus-admin', then: yard init)
MSG
      exit 0
    fi
  elif incus_too_old; then
    info "→ upgrade Incus (>= $MIN_INCUS_VER)"
    "$SCRIPT_DIR/01-install-incus.sh" --yes ${ZB[@]+"${ZB[@]}"} --upgrade-only \
      || die "incus upgrade failed"
  fi
}

run_steps() {
  incus_install_or_upgrade
  info "→ Incus project"; "$SCRIPT_DIR/02-create-project.sh" --yes
  info "→ yard instance"; "$SCRIPT_DIR/03-create-subyard.sh" --yes
  info "→ host network";  "$SCRIPT_DIR/06-network.sh" --yes
  info "→ host mounts";   "$SCRIPT_DIR/05-mount-host-paths.sh" --yes
  info "→ provision";     "$SCRIPT_DIR/04-provision-subyard.sh" --yes
  info "→ ssh access";    "$SCRIPT_DIR/07-ssh-access.sh" --yes
  info "→ git identity";  "$SCRIPT_DIR/08-git-identity.sh" --yes
  if any_yard_extras; then info "→ yard extras"; "$SCRIPT_DIR/09-yard-extras.sh" --yes; fi
}

# ============================================================================
# --configs / --reset special modes.
# ============================================================================
maybe_configs() {
  local a configs=0 reset=0
  for a in "$@"; do
    [ "$a" = --configs ] && configs=1
    [ "$a" = --reset ] && reset=1
  done
  [ "$configs" = 1 ] || return 0
  [ "$reset" = 0 ] || die "--configs and --reset cannot be used together"
  exec "$SCRIPT_DIR/agent-configs.sh" "$@"
}

maybe_reset() {
  local a reset=0
  for a in "$@"; do [ "$a" = --reset ] && reset=1; done
  [ "$reset" = 1 ] || return 0
  announce "yard init --reset — full rebuild" \
    "Tear down the yard: DELETE the instance and its disk data (rootfs + /srv), then re-init from current config." \
    "Host-side sessions under \$HOST_BASE/host-agent-sessions persist; per-yard agent creds are lost (you re-login)." \
    "Use this when a normal 'yard init' didn't pick up a config change."
  proceed_or_die
  info "→ teardown"; "$SCRIPT_DIR/99-teardown.sh" --yes || die "teardown failed"
  info "→ rebuild (fresh init)"; exec env ASSUME_YES=1 "$SCRIPT_DIR/init.sh"
}

# ============================================================================
# Main.
# ============================================================================
maybe_configs "$@"
maybe_reset "$@"

# Incus installed + daemon unreachable + you're already in 'incus-admin' = this shell
# predates the group. Don't show a misleading all-[do] plan — continue in a fresh
# group session (nothing to reinstall; it's all already there).
if incus_present && ! incus info >/dev/null 2>&1 && in_admin_db; then
  warn "Incus is installed and you're in 'incus-admin', but this shell session predates that group."
  reexec_under_group 0 || true
  cat <<'MSG'

Nothing to reinstall — continue in a fresh group session:
    sg incus-admin -c 'yard init'
  (or re-login / run 'newgrp incus-admin', then: yard init)
MSG
  exit 0
fi

# 1. Describe the plan (read-only). Nothing here mutates the host.
print_plan
if [ "$pending" = 0 ]; then
  ok "Everything is already set up — nothing to do."
  offer_provision   # a ready yard may still have an un-provisioned profile
  exit 0
fi

# 2. Read-only host preflight, now that we know there is work to do.
host_preflight

# 3. One confirmation covers the whole run: if Incus isn't set up yet, installing it
#    switches your group and init then continues UNATTENDED in a fresh session.
if ! have_init; then
  printf '%sNote:%s installing Incus adds you to '\''incus-admin'\''; init then continues\n' "$C_HEAD" "$C_OFF"
  printf '      in a fresh group session and runs the remaining steps without asking\n'
  printf '      again — this one confirmation covers them all.\n\n'
fi
proceed_or_die

# 4. Pick the Incus source — only when the distro package can't meet the floor.
#    Default YES to Zabbly; asked here, AFTER the main gate, never before it. A
#    group-session re-exec inherits the answer via SUBYARD_ZABBLY (set/0/1), so the
#    child never re-asks nor overrides an explicit "no" from the parent run.
ZB=()
if [ -n "${SUBYARD_ZABBLY:-}" ]; then
  [ "$SUBYARD_ZABBLY" = 1 ] && ZB=(--zabbly)
elif incus_too_old; then
  want_zabbly upgrade && ZB=(--zabbly)
elif ! incus_present && distro_incus_too_old; then
  want_zabbly install && ZB=(--zabbly)
fi

# 5. Do it.
run_steps

echo
ok "Subyard is up."
# Context-aware next steps: the default yard shows plain `yard …`; a named yard carries -Y so
# the copy-pasted commands target the same yard.
_hint="$(yard_cmd_hint)"
cat <<MSG

Next:
  $_hint status
  $_hint sync .       # copy a code project into the yard (or: bind . to mount it)
  $_hint code .       # open it in VS Code (Remote-SSH into the yard)
MSG
offer_provision
