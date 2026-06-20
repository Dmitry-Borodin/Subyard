#!/usr/bin/env bash
# 03-create-subyard.sh — Phase 2: launch the yard instance, pass /dev/kvm, attach /srv volume.
# Operator (incus-admin, no sudo). Idempotent. Decisions #1/#17/#18/#25.
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
BASE_IMAGE="${BASE_IMAGE:-images:debian/13}"
BASE_IMAGE_FALLBACK="${BASE_IMAGE_FALLBACK:-images:ubuntu/24.04}"
SRV_POOL="${SRV_POOL:-default}"
SRV_VOLUME="${SRV_VOLUME:-yard-srv}"
HOST_BASE="${HOST_BASE:-/srv/subyard}"
DEV_USER="${DEV_USER:-dev}"

PROJ=(--project "$INCUS_PROJECT")
device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# --- preconditions -----------------------------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run scripts/01-install-incus.sh first"
incus info >/dev/null 2>&1 \
  || die "cannot talk to the Incus daemon — run 01-install-incus.sh, then re-login (newgrp incus-admin)"
incus project show "$INCUS_PROJECT" >/dev/null 2>&1 \
  || die "project '$INCUS_PROJECT' missing — run scripts/02-create-project.sh first"

announce_confirm "Subyard Phase 2 — create yard instance" \
  "Launch Incus instance '$INSTANCE_NAME' ($INSTANCE_TYPE) from $BASE_IMAGE (fallback $BASE_IMAGE_FALLBACK)." \
  "Pass /dev/kvm through (container) and attach a persistent '$SRV_VOLUME' volume at /srv." \
  "Reversible: 'incus delete -f $INSTANCE_NAME ${PROJ[*]}' removes it."

# --- 1. create instance (idempotent) -----------------------------------------
echo "Instance:"
LAUNCH_FLAGS=()
if [ "$INSTANCE_TYPE" = vm ]; then
  LAUNCH_FLAGS+=(--vm)
  # qemu-system is needed only for vm mode — install lazily, never "just in case" (#25).
  if ! dpkg -s qemu-system-x86 >/dev/null 2>&1 && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    die "vm mode needs qemu — install it and re-run: sudo apt-get install qemu-system-x86"
  fi
else
  LAUNCH_FLAGS+=(-c security.nesting=true)
fi
[ -n "${LIMITS_CPU:-}" ]    && LAUNCH_FLAGS+=(-c "limits.cpu=$LIMITS_CPU")
[ -n "${LIMITS_MEMORY:-}" ] && LAUNCH_FLAGS+=(-c "limits.memory=$LIMITS_MEMORY")

if incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1; then
  ok "instance '$INSTANCE_NAME' exists"
else
  info "launching $INSTANCE_NAME from $BASE_IMAGE"
  if ! incus launch "$BASE_IMAGE" "$INSTANCE_NAME" "${PROJ[@]}" "${LAUNCH_FLAGS[@]}" 2>/dev/null; then
    warn "launch from $BASE_IMAGE failed; trying fallback $BASE_IMAGE_FALLBACK"
    incus launch "$BASE_IMAGE_FALLBACK" "$INSTANCE_NAME" "${PROJ[@]}" "${LAUNCH_FLAGS[@]}" \
      || die "instance launch failed (check image remotes and INSTANCE_TYPE)"
  fi
  ok "launched $INSTANCE_NAME"
fi

# Ensure it's RUNNING — covers resume after a partial setup or a host reboot
# (provision uses `incus exec`, which needs a running instance).
state="$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -c s -f csv 2>/dev/null || true)"
if [ "$state" != RUNNING ]; then
  info "starting $INSTANCE_NAME (was: ${state:-unknown})"
  incus start "$INSTANCE_NAME" "${PROJ[@]}"
fi

# --- 2. /dev/kvm passthrough (container only) --------------------------------
echo "KVM:"
if [ "$INSTANCE_TYPE" = vm ]; then
  ok "vm mode uses nested virtualization — no unix-char passthrough"
elif device_exists kvm; then
  ok "kvm device already attached"
elif [ -e /dev/kvm ]; then
  incus config device add "$INSTANCE_NAME" kvm unix-char "${PROJ[@]}" \
    source=/dev/kvm path=/dev/kvm mode=0660 >/dev/null
  ok "added /dev/kvm passthrough (gid fix deferred to Phase 3, after group 'kvm' exists)"
else
  warn "/dev/kvm absent on host — emulator won't be hardware-accelerated; skipping passthrough"
fi

# --- 3. persistent /srv volume (idempotent) ----------------------------------
echo "Storage (/srv):"
if incus storage volume show "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}" >/dev/null 2>&1; then
  ok "volume '$SRV_VOLUME' exists"
else
  incus storage volume create "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}" >/dev/null
  ok "created volume '$SRV_VOLUME' on pool '$SRV_POOL'"
fi
if device_exists srv; then
  ok "srv device already attached"
else
  incus config device add "$INSTANCE_NAME" srv disk "${PROJ[@]}" \
    pool="$SRV_POOL" source="$SRV_VOLUME" path=/srv >/dev/null
  ok "attached '$SRV_VOLUME' at /srv"
fi

# --- summary -----------------------------------------------------------------
echo
ok "Phase 2 (instance) done."
cat <<MSG

Verify:
  incus list "${PROJ[@]}"                  # $INSTANCE_NAME is RUNNING
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- ls -l /dev/kvm   # present (container)

Next:
  - scripts/05-mount-host-paths.sh   (host dirs under $HOST_BASE + /mnt/host/* mounts)
  - Phase 3 provisioning (packages, user '$DEV_USER', Docker, SSH) + kvm gid fix
MSG
