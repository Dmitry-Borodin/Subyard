#!/usr/bin/env bash
# 05-mount-host-paths.sh — Phase 2: create $HOST_BASE (/srv/subyard) and mount its
# subdirs into the yard as /mnt/host/* (secrets/devcontainers RO, shift). Root; idempotent.
# Host exposes ONLY $HOST_BASE. SHIFT_MODE=shift|acl.
# Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# --- load config -------------------------------------------------------------
for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INSTANCE_TYPE="${INSTANCE_TYPE:-container}"
HOST_BASE="${HOST_BASE:-/srv/subyard}"
SHIFT_MODE="${SHIFT_MODE:-shift}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"

PROJ=(--project "$INCUS_PROJECT")
device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# --- announce → confirm → sudo → checks → work -------------------------------
announce "Subyard Phase 2 — host mounts ($INSTANCE_NAME)" \
  "Create the narrow host area: $HOST_BASE/{host-secrets,host-memory,host-devcontainers,backups}." \
  "Mount it into the yard: /mnt/host/secrets (RO), /mnt/host/memory (RW), /mnt/host/devcontainers (RO)." \
  "Own shared dirs by uid $DEV_UID and mount with '$SHIFT_MODE' so they map 1:1 to '$DEV_USER' in the yard." \
  "The host exposes ONLY $HOST_BASE — no \$HOME/.ssh/etc."
proceed_or_die
require_root "the steps above create directories under /srv and attach host mounts to the yard"

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

# --- 1. create the narrow host area ------------------------------------------
echo "Host directories:"
declare -A DIR_MODE=(
  [host-secrets]=700
  [host-memory]=770
  [host-devcontainers]=755
  [backups]=755
)
# Shared dirs are owned by DEV_UID so the idmapped ('shift') mount maps them to the
# yard's 'dev' (host uid == container uid under shift). install -d also fixes an
# existing dir's owner/mode, so this self-heals dirs left root-owned by an older run.
for d in host-secrets host-memory host-devcontainers; do
  install -d -m "${DIR_MODE[$d]}" -o "$DEV_UID" -g "$DEV_UID" "$HOST_BASE/$d"
  ok "$HOST_BASE/$d (${DIR_MODE[$d]}, owner $DEV_UID)"
done
# 'backups' is a host-side backup target, never mounted into the yard — keep it root.
install -d -m "${DIR_MODE[backups]}" "$HOST_BASE/backups"
ok "$HOST_BASE/backups (${DIR_MODE[backups]}, root)"

# --- 2. attach host-mount devices (idempotent) -------------------------------
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
