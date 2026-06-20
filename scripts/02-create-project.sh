#!/usr/bin/env bash
#
# 02-create-project.sh — Phase 1: create the restricted Incus project for the yard.
#
# Creates the isolated Incus project (default: agent-dev) and applies the §5
# restricted.* policy so security-sensitive features stay off by default, with
# only the narrow exceptions Subyard needs: container nesting (Docker in the
# yard), host disk mounts limited to one prefix, and unix-char + proxy devices.
# Idempotent: safe to re-run.
#
# Runs as the operator (must be in incus-admin — no sudo). If Incus is not
# reachable, run scripts/01-install-incus.sh and re-login (newgrp incus-admin).
#
# Config: config/incus.project.env (sourced if present). Environment overrides win.
#   INCUS_PROJECT          project name              (default: agent-dev)
#   RESTRICTED_DISK_PATHS  allowed host-mount prefix (default: /srv/subyard)
#
set -euo pipefail

# --- locate + load config ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config/incus.project.env}"
# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

INCUS_PROJECT="${INCUS_PROJECT:-agent-dev}"
RESTRICTED_DISK_PATHS="${RESTRICTED_DISK_PATHS:-/srv/subyard}"

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_OFF=''
fi
ok()   { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
command -v incus >/dev/null 2>&1 \
  || die "incus not found — run scripts/01-install-incus.sh first"
incus info >/dev/null 2>&1 \
  || die "cannot talk to the Incus daemon — run 01-install-incus.sh, then re-login (newgrp incus-admin)"

echo "Subyard Incus project (Phase 1)"
echo "  project    : $INCUS_PROJECT"
echo "  disk paths : $RESTRICTED_DISK_PATHS"
echo

# --- 1. create project (idempotent) ------------------------------------------
echo "Project:"
if incus project show "$INCUS_PROJECT" >/dev/null 2>&1; then
  ok "project '$INCUS_PROJECT' exists"
else
  incus project create "$INCUS_PROJECT" >/dev/null
  ok "created project '$INCUS_PROJECT'"
fi

# --- 2. apply restricted.* policy (§5) ---------------------------------------
# restricted=true keeps sensitive features off; the rest re-enable only what the
# yard needs. restricted.devices.disk.paths is the key host-mount constraint.
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
