#!/usr/bin/env bash
# 02-create-project.sh — Phase 1: create the restricted Incus project (§5 policy).
# Operator (incus-admin, no sudo). Idempotent.
# Config: config/incus.project.env — INCUS_PROJECT (subyard), RESTRICTED_DISK_PATHS (/srv/subyard).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# --- load config -------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config/incus.project.env}"
# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
RESTRICTED_DISK_PATHS="${RESTRICTED_DISK_PATHS:-/srv/subyard}"

# --- preconditions -----------------------------------------------------------
command -v incus >/dev/null 2>&1 \
  || die "incus not found — run scripts/01-install-incus.sh first"
incus info >/dev/null 2>&1 \
  || die "cannot talk to the Incus daemon — run 01-install-incus.sh, then re-login (newgrp incus-admin)"

announce_confirm "Subyard Phase 1 — create restricted Incus project" \
  "Create Incus project '$INCUS_PROJECT' (if absent)." \
  "Apply the §5 restricted policy: nesting allow, host disk mounts limited to '$RESTRICTED_DISK_PATHS', unix-char + proxy allow." \
  "Reversible: 'incus project delete $INCUS_PROJECT' removes it."

# --- 1. create project (idempotent) ------------------------------------------
echo "Project:"
if incus project show "$INCUS_PROJECT" >/dev/null 2>&1; then
  ok "project '$INCUS_PROJECT' exists"
else
  incus project create "$INCUS_PROJECT" >/dev/null
  ok "created project '$INCUS_PROJECT'"
fi

# --- 2. apply restricted.* policy (§5) ---------------------------------------
# restricted=true keeps sensitive features off; re-enable only what the yard needs.
echo "Restricted policy (§5):"
set_key() {
  incus project set "$INCUS_PROJECT" "$1" "$2"
  ok "$1=$2"
}
set_key restricted true
set_key restricted.containers.nesting allow
set_key restricted.containers.privilege unprivileged
set_key restricted.devices.disk allow
set_key restricted.devices.disk.paths "$RESTRICTED_DISK_PATHS"
set_key restricted.devices.unix-char allow
set_key restricted.devices.proxy allow

# --- summary -----------------------------------------------------------------
echo
ok "Phase 1 step 2 done."
cat <<MSG

Verify:
  incus project list
  incus project show $INCUS_PROJECT   # expect the restricted.* keys above

Next:
  - Phase 2: scripts/03-create-subyard.sh (instance + /srv volume + /dev/kvm + host mounts)
MSG
