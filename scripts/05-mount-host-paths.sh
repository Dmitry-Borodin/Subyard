#!/usr/bin/env bash
#
# 05-mount-host-paths.sh — Phase 2: create the narrow host area and mount it.
#
# Creates the single allowed host-mount prefix ($HOST_BASE = /srv/subyard) with
# strict permissions, then attaches its subdirectories into the yard under
# /mnt/host/* with UID/GID shifting. Secrets and devcontainers are read-only.
# Idempotent: safe to re-run.
#
# Must run as root: it creates directories under /srv (host root fs) and adds
# Incus devices. §18 invariant: the host exposes ONLY $HOST_BASE to the yard —
# never $HOME, ~/.ssh, ~/.config, /var/run/docker.sock, /etc, /, etc.
#
# Decision #21: SHIFT_MODE=shift (idmapped, confirmed on host); acl is the
# fallback if a filesystem/kernel cannot do idmapped mounts.
#
# Config: config/incus.project.env + config/subyard.env (sourced if present).
#
set -euo pipefail

# --- locate + load config ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done

INCUS_PROJECT="${INCUS_PROJECT:-agent-dev}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INSTANCE_TYPE="${INSTANCE_TYPE:-container}"
HOST_BASE="${HOST_BASE:-/srv/subyard}"
SHIFT_MODE="${SHIFT_MODE:-shift}"
DEV_USER="${DEV_USER:-dev}"

PROJ=(--project "$INCUS_PROJECT")

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_OFF=''
fi
ok()   { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# --- preconditions -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root (creates dirs under /srv) — re-run with: sudo $0"
command -v incus >/dev/null 2>&1 || die "incus not found — run scripts/01-install-incus.sh first"
incus info >/dev/null 2>&1 || die "cannot talk to the Incus daemon (run 01-install-incus.sh, re-login)"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run scripts/03-create-subyard.sh first"

# shift vs acl
case "$SHIFT_MODE" in
  shift) SHIFT_OPT="shift=true" ;;
  acl)   SHIFT_OPT=""; warn "SHIFT_MODE=acl — mounts added without shift; apply POSIX ACLs separately" ;;
  *)     die "invalid SHIFT_MODE='$SHIFT_MODE' (expected: shift|acl)" ;;
esac
if [ "$INSTANCE_TYPE" = vm ]; then
  warn "vm mode uses virtiofs — 'shift' is not applicable (see a1-sensitive-deltas); review before use"
fi

echo "Subyard host mounts (Phase 2)"
echo "  host base : $HOST_BASE"
echo "  shift     : $SHIFT_MODE"
echo

# --- 1. create the narrow host area ------------------------------------------
echo "Host directories:"
declare -A DIR_MODE=(
  [host-secrets]=700
  [host-memory]=770
  [host-devcontainers]=755
  [backups]=755
)
for d in host-secrets host-memory host-devcontainers backups; do
  install -d -m "${DIR_MODE[$d]}" "$HOST_BASE/$d"
  ok "$HOST_BASE/$d (${DIR_MODE[$d]})"
done

# --- 2. attach host-mount devices (idempotent) -------------------------------
# name  hostsubdir          guestpath               extra-opts
echo "Host mounts → yard:"
add_mount() {
  local name="$1" sub="$2" path="$3" ro="$4"
  if device_exists "$name"; then
    ok "$name already attached"
    return
  fi
  local opts=(source="$HOST_BASE/$sub" path="$path")
  [ "$ro" = ro ] && opts+=(readonly=true)
  [ -n "$SHIFT_OPT" ] && opts+=("$SHIFT_OPT")
  incus config device add "$INSTANCE_NAME" "$name" disk "${PROJ[@]}" "${opts[@]}" >/dev/null
  ok "$name → $path${ro:+ ($ro)}"
}
add_mount host-secrets       host-secrets       /mnt/host/secrets       ro
add_mount host-memory        host-memory        /mnt/host/memory        rw
add_mount host-devcontainers host-devcontainers /mnt/host/devcontainers ro
# 'backups' stays host-side only (backup target) — not mounted into the yard.

# --- summary -----------------------------------------------------------------
echo
ok "Phase 2 (host mounts) done."
cat <<MSG

Verify:
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- ls -la /mnt/host
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- touch /mnt/host/secrets/x  # must FAIL (read-only)

Next:
  - Phase 3 provisioning: packages, user '$DEV_USER', Docker, SSH, then the kvm gid fix.
MSG
