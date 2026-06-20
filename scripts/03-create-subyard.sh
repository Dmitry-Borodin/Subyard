#!/usr/bin/env bash
#
# 03-create-subyard.sh — Phase 2: create the yard instance + /dev/kvm + /srv volume.
#
# Launches the yard (system container by default; vm via INSTANCE_TYPE=vm),
# passes /dev/kvm through (container), and attaches a persistent custom volume
# at /srv that survives an instance rebuild. Idempotent: safe to re-run.
#
# Runs as the operator (must be in incus-admin — no sudo). Host directories and
# host-mount devices come next, in scripts/05-mount-host-paths.sh.
#
# Decisions encoded: container default + vm parameter (#1); Debian 13 base, Ubuntu
# fallback (#17); no cpu/memory limits by default (#18); qemu installed lazily for
# vm only (#25). Host mounts and the kvm-gid fix happen in later phases.
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
BASE_IMAGE="${BASE_IMAGE:-images:debian/13}"
BASE_IMAGE_FALLBACK="${BASE_IMAGE_FALLBACK:-images:ubuntu/24.04}"
SRV_POOL="${SRV_POOL:-default}"
SRV_VOLUME="${SRV_VOLUME:-yard-srv}"
HOST_BASE="${HOST_BASE:-/srv/subyard}"
DEV_USER="${DEV_USER:-dev}"

PROJ=(--project "$INCUS_PROJECT")

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_OFF=''
fi
info() { printf '  %s[ .. ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# --- preconditions -----------------------------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run scripts/01-install-incus.sh first"
incus info >/dev/null 2>&1 \
  || die "cannot talk to the Incus daemon — run 01-install-incus.sh, then re-login (newgrp incus-admin)"
incus project show "$INCUS_PROJECT" >/dev/null 2>&1 \
  || die "project '$INCUS_PROJECT' missing — run scripts/02-create-project.sh first"

echo "Subyard yard instance (Phase 2)"
echo "  project  : $INCUS_PROJECT"
echo "  instance : $INSTANCE_NAME ($INSTANCE_TYPE)"
echo "  base     : $BASE_IMAGE (fallback $BASE_IMAGE_FALLBACK)"
echo

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
