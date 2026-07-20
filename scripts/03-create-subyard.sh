#!/usr/bin/env bash
# 03-create-subyard.sh — Phase 2: create the yard instance, pass /dev/kvm, attach /srv volume.
# Operator (incus-admin, no sudo). Idempotent.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INSTANCE_TYPE="${INSTANCE_TYPE:-container}"
BASE_IMAGE="${BASE_IMAGE:-images:debian/13}"
BASE_IMAGE_FALLBACK="${BASE_IMAGE_FALLBACK:-images:ubuntu/24.04}"
SRV_POOL="${SRV_POOL:-default}"
SRV_VOLUME="${SRV_VOLUME:-yard-srv}"
DEV_USER="${DEV_USER:-dev}"
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
YARD_LABEL="${YARD_NAME:-default}"

PROJ=(--project "$INCUS_PROJECT")
device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# --- preconditions -----------------------------------------------------------
incus_preflight
incus project show "$INCUS_PROJECT" >/dev/null 2>&1 \
  || die "project '$INCUS_PROJECT' missing — run scripts/02-create-project.sh first"

announce_confirm "Subyard Phase 2 — create yard instance" \
  "Create Incus instance '$INSTANCE_NAME' ($INSTANCE_TYPE) from $BASE_IMAGE (fallback $BASE_IMAGE_FALLBACK)." \
  "Pass /dev/kvm through (container) and attach a persistent '$SRV_VOLUME' volume at /srv." \
  "Reversible: 'incus delete -f $INSTANCE_NAME ${PROJ[*]}' removes it."
power_nm_prepare_reader || die "$POWER_ERROR"

# --- 1. create instance (idempotent) -----------------------------------------
echo "Instance:"
LAUNCH_FLAGS=()
if [ "$INSTANCE_TYPE" = vm ]; then
  LAUNCH_FLAGS+=(--vm)
  # qemu-system only for vm mode — installed lazily.
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
  if [ "$INSTANCE_TYPE" = container ] \
    && [ "$(incus config get "$INSTANCE_NAME" security.nesting "${PROJ[@]}" 2>/dev/null || true)" != true ]; then
    incus config set "$INSTANCE_NAME" security.nesting true "${PROJ[@]}"
    ok "reconciled security.nesting=true"
  fi
  power_import_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
    || die "$POWER_ERROR"
  [ "$POWER_IMPORTED" = 0 ] || ok "imported existing power state as desired=$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
else
  initial_desired="$(power_initial_desired "$YARD_LABEL")"
  LAUNCH_FLAGS+=(
    -c boot.autostart=false
    -c "$POWER_KEY_MANAGED=true"
    -c "$POWER_KEY_NAME=$YARD_LABEL"
    -c "$POWER_KEY_BRIDGE=$BRIDGE"
    -c "$POWER_KEY_DESIRED=$initial_desired"
    -c "$POWER_KEY_INITIALIZED=false"
  )
  info "creating $INSTANCE_NAME from $BASE_IMAGE"
  if err="$(incus init "$BASE_IMAGE" "$INSTANCE_NAME" "${PROJ[@]}" "${LAUNCH_FLAGS[@]}" 2>&1)"; then
    ok "created $INSTANCE_NAME"
  elif incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1; then
    warn "instance '$INSTANCE_NAME' was created with an initialization warning:"
    printf '%s\n' "$err" >&2
  elif printf '%s' "$err" | grep -qiE 'image|not found|no such|remote'; then
    # Only the base image looks missing — try the fallback. Other failures (e.g. a
    # missing root device) would just repeat, so surface them instead of retrying.
    warn "create from $BASE_IMAGE failed (image unavailable); trying fallback $BASE_IMAGE_FALLBACK"
    incus init "$BASE_IMAGE_FALLBACK" "$INSTANCE_NAME" "${PROJ[@]}" "${LAUNCH_FLAGS[@]}" \
      || die "instance creation failed (check image remotes and INSTANCE_TYPE)"
    ok "created $INSTANCE_NAME (fallback image)"
  else
    printf '%s\n' "$err" >&2
    die "instance creation failed"
  fi
fi

# Ensure it's RUNNING temporarily — provision uses `incus exec`. Final init reconciliation restores
# the persisted desired state, so a fresh named yard is stopped again before `yard init` returns.
state="$(power_state "$INCUS_PROJECT" "$INSTANCE_NAME")"
[ "$state" = RUNNING ] || info "starting $INSTANCE_NAME temporarily (was: ${state:-unknown})"
power_start_guarded "$INCUS_PROJECT" "$INSTANCE_NAME" "$BRIDGE" || die "$POWER_ERROR"
power_enforce_autostart_false "$INCUS_PROJECT" "$INSTANCE_NAME" || die "could not disable Incus boot.autostart"

# --- 2. /dev/kvm passthrough (container only) --------------------------------
echo "KVM:"
if [ "$INSTANCE_TYPE" = vm ]; then
  ok "vm mode uses nested virtualization — no unix-char passthrough"
elif device_exists kvm; then
  ok "kvm device already attached"
elif [ -e /dev/kvm ]; then
  # Nested hosts (this host is itself a container) reject the mode property on unix-char
  # devices — retry without it.
  if ! err="$(incus config device add "$INSTANCE_NAME" kvm unix-char "${PROJ[@]}" \
        source=/dev/kvm path=/dev/kvm mode=0660 2>&1 >/dev/null)"; then
    case "$err" in
      *"nested container"*)
        incus config device add "$INSTANCE_NAME" kvm unix-char "${PROJ[@]}" \
          source=/dev/kvm path=/dev/kvm >/dev/null
        warn "nested host: /dev/kvm attached without an explicit mode" ;;
      *) printf '%s\n' "$err" >&2; die "could not attach /dev/kvm" ;;
    esac
  fi
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
srv_drifted=0
if device_exists srv; then
  [ "$(incus config device get "$INSTANCE_NAME" srv pool "${PROJ[@]}" 2>/dev/null || true)" = "$SRV_POOL" ] \
    && [ "$(incus config device get "$INSTANCE_NAME" srv source "${PROJ[@]}" 2>/dev/null || true)" = "$SRV_VOLUME" ] \
    && [ "$(incus config device get "$INSTANCE_NAME" srv path "${PROJ[@]}" 2>/dev/null || true)" = /srv ] \
    || srv_drifted=1
  if [ "$srv_drifted" = 0 ]; then
    ok "srv device already attached"
  else
    warn "srv device drifted — re-attaching to '$SRV_VOLUME' at /srv"
    incus config device remove "$INSTANCE_NAME" srv "${PROJ[@]}" >/dev/null
  fi
fi
if ! device_exists srv; then
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
