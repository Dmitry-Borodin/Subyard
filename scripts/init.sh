#!/usr/bin/env bash
# init.sh — one-shot yard bring-up (yard init): check → install →
# project → create → mounts → provision. Idempotent and resumable.
# One upfront confirm; steps that need root self-elevate via sudo. Flag -y.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

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
have_mounts()   { reachable && incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx host-secrets; }
have_provision(){ reachable && incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -c 'command -v docker >/dev/null && id dev >/dev/null' >/dev/null 2>&1; }
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

# Incus installed + daemon unreachable + you ARE in incus-admin (per the group db)
# = this shell session just predates the group. Don't show a blind all-[do] plan;
# route to a fresh group session (no reinstall — everything is already there).
if command -v incus >/dev/null 2>&1 && ! incus info >/dev/null 2>&1 && in_admin_db; then
  warn "Incus is installed and you're in 'incus-admin', but this shell session predates that group."
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

if [ "$pending" = 0 ]; then
  ok "Everything is already set up — nothing to do."
  exit 0
fi
proceed_or_die

STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME}" "$SCRIPT_DIR/00-check-host.sh"

# Install Incus on first run. Adding you to incus-admin only takes effect in a
# fresh group session, so if Incus still isn't reachable after install, stop and
# print the one command to continue.
if ! have_init; then
  info "→ install / init Incus"
  "$SCRIPT_DIR/01-install-incus.sh" --yes
  if ! reachable; then
    echo
    ok "Incus installed and you're added to 'incus-admin'."
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
