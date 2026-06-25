#!/usr/bin/env bash
# init.sh — one-shot yard bring-up (yard init): check → install → project → create →
# mounts → provision. Idempotent and resumable; one upfront confirm; root steps self-elevate
# via sudo. After installing Incus it re-execs under a fresh 'incus-admin' group session so a
# single run completes end-to-end. A re-run reconciles config drift (mounts, provision
# artifacts), but conservatively — it may miss a content/dotfiles change.
#
# Usage: yard init [--reset] [-y]
#
# Options:
#   --reset      Teardown the yard, then a fresh init — force-apply a config change the
#                conservative reconcile didn't pick up. Asks before doing anything.
#   -y, --yes    Skip the confirmation prompt (for automation/CI).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")   # preserved so we can re-exec ourselves under a fresh group session
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Installing Incus adds the operator to 'incus-admin', but that group only takes effect in
# a fresh session, so the daemon stays unreachable in THIS shell. Instead of stopping and
# making the operator re-run, re-exec the whole init under a fresh group session ('sg') so
# one 'yard init' runs end-to-end. Guarded against looping (SUBYARD_SG_REEXEC); returns
# non-zero so callers fall back to the manual hint if 'sg' is missing or the retry still
# can't connect. $1=1 => assume-yes in the child (the top plan was already confirmed).
reexec_under_group() {
  [ "${SUBYARD_SG_REEXEC:-0}" = 1 ] && return 1
  command -v sg >/dev/null 2>&1 || return 1
  local q; printf -v q '%q ' "$SCRIPT_DIR/init.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  local pre="SUBYARD_SG_REEXEC=1"; [ "${1:-0}" = 1 ] && pre+=" ASSUME_YES=1"
  info "continuing under a fresh 'incus-admin' group session (no manual re-run needed)…"
  exec sg incus-admin -c "$pre exec $q"
}

# --- config (names the state probes below need) ------------------------------
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INCUS_BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
STORAGE_POOL="${STORAGE_POOL:-default}"
PROJ=(--project "$INCUS_PROJECT")

# --- read-only state probes so the plan shows what THIS run will really do ----
reachable()     { command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; }
# 01 is "done" only if the daemon is reachable AND its storage pool + bridge exist.
# 'yard teardown' removes the pool/bridge but leaves Incus installed/reachable, so a
# bare reachability test would wrongly skip re-init and 02 would fail (no incusbr0).
have_init()     { reachable && incus storage show "$STORAGE_POOL" >/dev/null 2>&1 \
                            && incus network show "$INCUS_BRIDGE" >/dev/null 2>&1; }
have_project()  { reachable && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; }
have_instance() { reachable && incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1; }
have_network()  { [ -n "$(reachable && incus list "$INSTANCE_NAME" "${PROJ[@]}" -c4 -fcsv 2>/dev/null)" ]; }
# Every device named in HOST_MOUNTS is attached → adding/removing a mount in config re-runs 05.
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
# docker + dev, plus the config-driven artifacts 04 applies (CLAUDE.md copied, HOST_LINKS
# symlinks present, dev sudoers matching DEV_SUDO) — so a config change re-runs provision.
# PRESENCE checks only (no content compare), so it never flip-flops; content/dotfiles refresh
# is deliberately NOT caught here — use 'yard init --reset' (or a direct provision) for that.
have_provision() {
  reachable || return 1
  local claude_req=0
  [ -n "${HOST_CLAUDE_MD:-}" ] && [ -f "$HOST_CLAUDE_MD" ] && claude_req=1
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env DEV_USER="${DEV_USER:-dev}" --env DEV_SUDO="${DEV_SUDO:-0}" \
    --env CLAUDE_REQ="$claude_req" --env HOST_LINKS="${HOST_LINKS:-}" \
    -- sh -s >/dev/null 2>&1 <<'CHK'
set -eu
command -v docker >/dev/null
id "$DEV_USER" >/dev/null
home="$(getent passwd "$DEV_USER" | cut -d: -f6)"; home="${home:-/home/$DEV_USER}"
if [ "${CLAUDE_REQ:-0}" = 1 ]; then [ -f "$home/.claude/CLAUDE.md" ]; fi
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
have_ssh()      { reachable && incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh; }
have_gitid()    { reachable && incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -s "/home/${DEV_USER:-dev}/.gitconfig" >/dev/null 2>&1; }
in_admin_db()   { id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; }
# Some in-yard project's profile requests yard-level extras (YARD_*)? jq-guarded so a
# fresh host (no jq, no projects yet) simply reports none. 09-yard-extras is idempotent,
# so "pending" here just means "reconcile the union" — re-applying is harmless.
any_yard_extras() {
  command -v jq >/dev/null 2>&1 || return 1
  local sd="$SUBYARD_CONFIG_HOME/projects" f prof pf
  [ -d "$sd" ] || return 1
  for f in "$sd"/*.json; do
    [ -e "$f" ] || continue
    prof="$(jq -r '.profile // ""' "$f" 2>/dev/null)"; [ -n "$prof" ] || continue
    pf="$SCRIPT_DIR/../config/profiles/$prof/profile.conf"; [ -r "$pf" ] || continue
    # shellcheck disable=SC1090
    ( . "$pf"; [ -n "${YARD_MOUNTS:-}${YARD_CAPS:-}${YARD_DEVICES:-}" ] ) && return 0
  done
  return 1
}
no_yard_extras() { ! any_yard_extras; }

# In-yard projects' declared profiles that ship a provision.sh — i.e. a toolchain you can install
# into the yard with `yard provision`. Drives the opt-in provision offer below. One profile per line;
# jq-guarded so a fresh host with no projects simply prints nothing.
provisionable_profiles() {
  command -v jq >/dev/null 2>&1 || return 0
  local sd="$SUBYARD_CONFIG_HOME/projects" f prof
  [ -d "$sd" ] || return 0
  for f in "$sd"/*.json; do
    [ -e "$f" ] || continue
    prof="$(jq -r '.profile // ""' "$f" 2>/dev/null)"; [ -n "$prof" ] || continue
    [ -r "$SCRIPT_DIR/../config/profiles/$prof/provision.sh" ] && printf '%s\n' "$prof"
  done | sort -u
}

# Opt-in provision offer at the end of init — default N, and NEVER under -y/automation (provisioning
# is HEAVY: it downloads Node/JDK/SDK). Prompts only on an interactive TTY when an in-yard project
# actually declares a provisionable profile; a fresh yard with no such project just gets a one-line
# discovery hint. A 'yes' runs the provision driver (which announces, then installs because --yes
# skips its own gate — init already asked).
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

# --reset: teardown then a fresh init — the guaranteed full re-apply for a config change the
# (deliberately safe, may-miss) reconcile doesn't catch. Asks once, then rebuilds with -y.
RESET=0; for _a in "$@"; do [ "$_a" = --reset ] && RESET=1; done; unset _a
if [ "$RESET" = 1 ]; then
  announce "yard init --reset — full rebuild" \
    "Tear down the yard: DELETE the instance and its disk data (rootfs + /srv), then re-init from current config." \
    "Host-side sessions under \$HOST_BASE/host-agent-sessions persist; per-yard agent creds are lost (you re-login)." \
    "Use this when a normal 'yard init' didn't pick up a config change."
  proceed_or_die
  info "→ teardown"; "$SCRIPT_DIR/99-teardown.sh" --yes || die "teardown failed"
  info "→ rebuild (fresh init)"; exec env ASSUME_YES=1 "$SCRIPT_DIR/init.sh"
fi

# Incus installed + daemon unreachable + you ARE in incus-admin (per the group db)
# = this shell session just predates the group. Don't show a blind all-[do] plan;
# route to a fresh group session (no reinstall — everything is already there).
if command -v incus >/dev/null 2>&1 && ! incus info >/dev/null 2>&1 && in_admin_db; then
  warn "Incus is installed and you're in 'incus-admin', but this shell session predates that group."
  reexec_under_group 0 || true
  cat <<'MSG'

Nothing to reinstall — continue in a fresh group session:
    sg incus-admin -c 'yard init'
  (or re-login / run 'newgrp incus-admin', then: yard init)
MSG
  exit 0
fi

# Print [skip] if the done-test passes, else [do] and mark work pending.
step() {  # <done-test> <label>
  if "$1"; then printf '  %s[skip]%s %s\n' "$C_WARN" "$C_OFF" "$2"
  else          printf '  %s[do]%s   %s\n' "$C_OK"   "$C_OFF" "$2"; pending=1; fi
}

printf '\n%sSubyard init — full bring-up%s\n%sThis run will (already-done steps are skipped):%s\n' \
  "$C_HEAD" "$C_OFF" "$C_HEAD" "$C_OFF"
pending=0
step have_init      "Install Incus + add you to incus-admin + init storage (needs root)"
step have_project   "Create the Incus project '$INCUS_PROJECT'"
step have_instance  "Create the yard instance (+ /dev/kvm, /srv volume)"
step have_network   "Open host DHCP/DNS for the yard bridge (ufw; needs root)"
step have_mounts    "Create host dirs under $HOST_BASE and mount them (needs root)"
step have_provision "Provision the yard (packages, Docker, user, services)"
step have_ssh       "Set up SSH access into the yard (proxy + your key)"
step have_gitid     "Give the in-yard 'dev' user a git identity (from host/config)"
step no_yard_extras "Apply yard extras requested by projects (mounts/caps/devices)"
printf '\n'

# If Incus isn't set up yet, installing it switches your group, after which init
# continues UNATTENDED in a fresh session. Say so here so this one confirmation is
# informed consent for the steps above that will run after that switch.
if ! have_init; then
  printf '%sNote:%s installing Incus adds you to '\''incus-admin'\''; init then continues\n' "$C_HEAD" "$C_OFF"
  printf '      automatically in a fresh group session and runs the remaining steps\n'
  printf '      above without asking again — this single confirmation covers them all.\n\n'
fi

if [ "$pending" = 0 ]; then
  ok "Everything is already set up — nothing to do."
  offer_provision   # a ready yard may still have an un-provisioned profile — offer it (opt-in)
  exit 0
fi
proceed_or_die

STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME}" "$SCRIPT_DIR/00-check-host.sh"

# Install Incus on first run. Adding you to incus-admin only takes effect in a
# fresh group session, so if Incus still isn't reachable after install, re-exec
# under one (sg) to carry through; the manual hint below is the fallback.
if ! have_init; then
  info "→ install / init Incus"
  "$SCRIPT_DIR/01-install-incus.sh" --yes
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
fi

info "→ Incus project"; "$SCRIPT_DIR/02-create-project.sh" --yes
info "→ yard instance"; "$SCRIPT_DIR/03-create-subyard.sh" --yes
info "→ host network";  "$SCRIPT_DIR/06-network.sh" --yes
info "→ host mounts";   "$SCRIPT_DIR/05-mount-host-paths.sh" --yes
info "→ provision";     "$SCRIPT_DIR/04-provision-subyard.sh" --yes
info "→ ssh access";    "$SCRIPT_DIR/07-ssh-access.sh" --yes
info "→ git identity";  "$SCRIPT_DIR/08-git-identity.sh" --yes
if any_yard_extras; then info "→ yard extras"; "$SCRIPT_DIR/09-yard-extras.sh" --yes; fi

echo
ok "Subyard is up."
cat <<'MSG'

Next:
  yard status
  yard sync .       # copy a code project into the yard (or: bind . to mount it)
  yard code .       # open it in VS Code (Remote-SSH into the yard)
MSG
# Offer to install project toolchains now — opt-in (default N), never auto-runs under -y/automation.
offer_provision
