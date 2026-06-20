#!/usr/bin/env bash
# setup.sh — one-shot yard bring-up (yard setup / yard init): check → install →
# project → create → mounts → provision. Idempotent and resumable.
# One upfront confirm; steps that need root self-elevate via sudo. Flag -y.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

reachable() { command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; }

announce "Subyard setup — full bring-up" \
  "Check the host." \
  "Install Incus + add you to incus-admin + init storage (needs root)." \
  "Create the Incus project 'subyard'." \
  "Create the yard instance (+ /dev/kvm, /srv volume)." \
  "Open host DHCP/DNS for the yard bridge if a firewall blocks it (needs root)." \
  "Create host dirs under /srv/subyard and mount them (needs root)." \
  "Provision the yard (packages, Docker, user, services)." \
  "Idempotent — already-done steps are skipped; safe to re-run."
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

echo
ok "Subyard is up."
cat <<'MSG'

Next:
  yard status
  yard import .     # bring a code project into the yard
MSG
