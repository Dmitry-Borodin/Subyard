#!/usr/bin/env bash
# setup.sh — one-shot yard bring-up (yard setup / yard init): check → install →
# project → create → mounts → provision. Idempotent and resumable.
# One upfront confirm; steps that need root self-elevate via sudo. Flag -y.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# --- config (names the state probes below need) ------------------------------
for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
HOST_BASE="${HOST_BASE:-/srv/subyard}"
PROJ=(--project "$INCUS_PROJECT")

# --- read-only state probes so the plan shows what THIS run will really do ----
reachable()     { command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; }
have_project()  { reachable && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; }
have_instance() { reachable && incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1; }
have_network()  { [ -n "$(reachable && incus list "$INSTANCE_NAME" "${PROJ[@]}" -c4 -fcsv 2>/dev/null)" ]; }
have_mounts()   { reachable && incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx host-secrets; }
have_provision(){ reachable && incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -c 'command -v docker >/dev/null && id dev >/dev/null' >/dev/null 2>&1; }
have_ssh()      { reachable && incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh; }
in_admin_db()   { id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; }

# Incus installed + daemon unreachable + you ARE in incus-admin (per the group db)
# = this shell session just predates the group. Don't show a blind all-[do] plan;
# route to a fresh group session (no reinstall — everything is already there).
if command -v incus >/dev/null 2>&1 && ! incus info >/dev/null 2>&1 && in_admin_db; then
  warn "Incus is installed and you're in 'incus-admin', but this shell session predates that group."
  cat <<'MSG'

Nothing to reinstall — continue in a fresh group session:
    sg incus-admin -c 'yard setup'
  (or re-login / run 'newgrp incus-admin', then: yard setup)
MSG
  exit 0
fi

# Print [skip] if the done-test passes, else [do] and mark work pending.
step() {  # <done-test> <label>
  if "$1"; then printf '  %s[skip]%s %s\n' "$C_WARN" "$C_OFF" "$2"
  else          printf '  %s[do]%s   %s\n' "$C_OK"   "$C_OFF" "$2"; pending=1; fi
}

printf '\n%sSubyard setup — full bring-up%s\n%sThis run will (already-done steps are skipped):%s\n' \
  "$C_HEAD" "$C_OFF" "$C_HEAD" "$C_OFF"
pending=0
step reachable      "Install Incus + add you to incus-admin + init storage (needs root)"
step have_project   "Create the Incus project '$INCUS_PROJECT'"
step have_instance  "Create the yard instance (+ /dev/kvm, /srv volume)"
step have_network   "Open host DHCP/DNS for the yard bridge (ufw; needs root)"
step have_mounts    "Create host dirs under $HOST_BASE and mount them (needs root)"
step have_provision "Provision the yard (packages, Docker, user, services)"
step have_ssh       "Set up SSH access into the yard (proxy + your key)"
printf '\n'

if [ "$pending" = 0 ]; then
  ok "Everything is already set up — nothing to do."
  exit 0
fi
proceed_or_die

STORAGE_PATH="${STORAGE_PATH:-$HOME/.subyard}" "$SCRIPT_DIR/00-check-host.sh"

# Install Incus on first run. Adding you to incus-admin only takes effect in a
# fresh group session, so if Incus still isn't reachable after install, stop and
# print the one command to continue.
if ! reachable; then
  info "→ install Incus"
  "$SCRIPT_DIR/01-install-incus.sh" --yes
  if ! reachable; then
    echo
    ok "Incus installed and you're added to 'incus-admin'."
    cat <<'MSG'

One step needs a fresh group session. Continue with:
    sg incus-admin -c 'yard setup'
  (or re-login / run 'newgrp incus-admin', then: yard setup)
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

echo
ok "Subyard is up."
cat <<'MSG'

Next:
  yard status
  yard import .     # bring a code project into the yard
  yard code .       # open it in VS Code (Remote-SSH into the yard)
MSG
