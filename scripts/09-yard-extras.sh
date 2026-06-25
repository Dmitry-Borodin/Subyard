#!/usr/bin/env bash
# 09-yard-extras.sh — Phase 2b: reconcile yard-level extras DECLARED BY PROFILES.
# Each profile may declare what it wants ON the yard (level 1):
#   YARD_MOUNTS   "<name>:<yard-path>:<ro|rw>:<mode>"   extra host mounts (under HOST_BASE)
#   YARD_CAPS     nesting rootless-docker fuse ...       instance capabilities
#   YARD_DEVICES  kvm fuse gpu ...                       instance devices (/dev passthrough; gpu=host GPU)
# P1: the yard gets the UNION across ALL on-disk profiles in config/profiles/ (P2 makes this configurable). Operator-run
# (incus-admin); only host-dir creation for YARD_MOUNTS uses sudo. Capabilities that need a
# restart are SET now; the operator is told to restart via the GUARDED path (yard stop/start)
# so the host's network guard runs — the host itself is never touched. Idempotent.
# Config: config/incus.project.env + config/subyard.env + config/profiles/*/profile.conf.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SHIFT_MODE="${SHIFT_MODE:-shift}"
DEV_UID="${DEV_UID:-1000}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }
dev_get() { incus config device get "$INSTANCE_NAME" "$1" "$2" "${PROJ[@]}" 2>/dev/null || true; }
cfg_get() { incus config get "$INSTANCE_NAME" "$1" "${PROJ[@]}" 2>/dev/null || true; }
case "$SHIFT_MODE" in shift) SHIFT_OPT="shift=true" ;; *) SHIFT_OPT="" ;; esac

# --- collect the UNION of YARD_* across profiles -----------------------------
# P1: enable ALL on-disk profiles (union their YARD_*); P2 makes the active set configurable.
u_mounts=(); u_caps=(); u_devs=()
for pf in "$PROFILES_DIR"/*/profile.conf; do
  [ -r "$pf" ] || continue
  while IFS= read -r line; do
    case "$line" in
      MOUNT\ *) u_mounts+=("${line#MOUNT }") ;;
      CAP\ *)   u_caps+=("${line#CAP }") ;;
      DEV\ *)   u_devs+=("${line#DEV }") ;;
    esac
  done < <( # subshell so each profile's YARD_* can't clobber ours
    # shellcheck disable=SC1090
    . "$pf"
    for m in ${YARD_MOUNTS:-}; do echo "MOUNT $m"; done
    for c in ${YARD_CAPS:-};    do echo "CAP $c"; done
    for d in ${YARD_DEVICES:-}; do echo "DEV $d"; done
  )
done
mapfile -t u_mounts < <(printf '%s\n' ${u_mounts[@]+"${u_mounts[@]}"} | sed '/^$/d' | sort -u)
mapfile -t u_caps   < <(printf '%s\n' ${u_caps[@]+"${u_caps[@]}"}     | sed '/^$/d' | sort -u)
mapfile -t u_devs   < <(printf '%s\n' ${u_devs[@]+"${u_devs[@]}"}     | sed '/^$/d' | sort -u)

if [ "${#u_mounts[@]}" -eq 0 ] && [ "${#u_caps[@]}" -eq 0 ] && [ "${#u_devs[@]}" -eq 0 ]; then
  ok "No project requests yard extras — nothing to do."
  exit 0
fi

# --- announce → confirm ------------------------------------------------------
summary=()
[ "${#u_mounts[@]}" -gt 0 ] && summary+=("Mounts onto the yard: ${u_mounts[*]}")
[ "${#u_caps[@]}"   -gt 0 ] && summary+=("Capabilities: ${u_caps[*]} (may need a yard restart)")
[ "${#u_devs[@]}"   -gt 0 ] && summary+=("Devices: ${u_devs[*]}")
announce "Subyard Phase 2b — yard extras requested by projects ($INSTANCE_NAME)" \
  "Apply the UNION of YARD_* across in-yard projects to the shared yard." \
  "${summary[@]}" \
  "Detach yx-* mounts no longer requested. The yard is shared and rebuildable; the host is untouched."
proceed_or_die

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"

# --- 1. mounts (yx-* devices, host dirs under HOST_BASE) ---------------------
want_mounts=""
if [ "${#u_mounts[@]}" -gt 0 ]; then
  echo "Yard extra mounts:"
fi
for entry in ${u_mounts[@]+"${u_mounts[@]}"}; do
  IFS=: read -r mn mp mro mmode <<<"$entry"
  [ -n "$mn" ] && [ -n "$mp" ] || { warn "bad YARD_MOUNTS entry '$entry' — skipping"; continue; }
  dev="yx-$mn"; src="$HOST_BASE/$mn"; want_mounts="$want_mounts $dev"
  sudo install -d -m "${mmode:-0755}" -o "$DEV_UID" -g "$DEV_UID" "$src"
  want_ro=0; [ "$mro" = ro ] && want_ro=1
  if device_exists "$dev"; then
    cur_ro=0; [ "$(dev_get "$dev" readonly)" = true ] && cur_ro=1
    if [ "$(dev_get "$dev" source)" = "$src" ] && [ "$(dev_get "$dev" path)" = "$mp" ] && [ "$cur_ro" = "$want_ro" ]; then
      ok "$dev → $mp (${mro:-rw}) unchanged"; continue
    fi
    warn "$dev drifted — re-attaching"
    incus config device remove "$INSTANCE_NAME" "$dev" "${PROJ[@]}" >/dev/null
  fi
  opts=(source="$src" path="$mp")
  [ "$want_ro" = 1 ] && opts+=(readonly=true)
  [ -n "$SHIFT_OPT" ] && opts+=("$SHIFT_OPT")
  incus config device add "$INSTANCE_NAME" "$dev" disk "${PROJ[@]}" "${opts[@]}" >/dev/null
  ok "$dev → $mp (${mro:-rw})"
done
# detach yx-* mounts no project requests anymore
while IFS= read -r d; do
  case "$d" in yx-*) ;; *) continue ;; esac
  case " $want_mounts " in *" $d "*) continue ;; esac
  warn "detaching '$d' — no project requests it"
  incus config device remove "$INSTANCE_NAME" "$d" "${PROJ[@]}" >/dev/null
done < <(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null)

# --- 2. capabilities (instance config; some need a restart) ------------------
restart_needed=0
set_cfg() {  # <key> <value> — set if it differs; flag restart
  local k="$1" v="$2"
  [ "$(cfg_get "$k")" = "$v" ] && { ok "$k=$v already"; return; }
  incus config set "$INSTANCE_NAME" "$k" "$v" "${PROJ[@]}"
  ok "set $k=$v"; restart_needed=1
}
need_fuse=0
for c in ${u_caps[@]+"${u_caps[@]}"}; do
  case "$c" in
    nesting|rootless-docker)
      set_cfg security.nesting true
      set_cfg security.idmap.size 1000000
      set_cfg security.syscalls.intercept.mknod true
      set_cfg security.syscalls.intercept.setxattr true
      need_fuse=1 ;;
    fuse) need_fuse=1 ;;
    *) warn "unknown YARD_CAP '$c' — skipping" ;;
  esac
done

# --- 3. devices (/dev passthrough as unix-char) ------------------------------
ensure_unix_char() {  # <device-name> <host-source>
  local name="$1" source="$2"
  device_exists "$name" && { ok "$name present"; return; }
  [ -e "$source" ] || { warn "$source absent on host — skipping $name"; return; }
  incus config device add "$INSTANCE_NAME" "$name" unix-char "${PROJ[@]}" \
    source="$source" path="$source" mode=0666 >/dev/null
  ok "$name → $source"
}
# 'gpu' → pass the host GPU (Incus gpu device → /dev/dri, incl. render node for headless GLES).
ensure_gpu() {  # <device-name>
  local name="$1"
  device_exists "$name" && { ok "$name present"; return; }
  [ -e /dev/dri ] || { warn "/dev/dri absent on host — no GPU to pass (profile requires one); skipping $name"; return; }
  incus config device add "$INSTANCE_NAME" "$name" gpu "${PROJ[@]}" >/dev/null \
    && ok "$name → host GPU (/dev/dri)" || warn "could not add gpu device '$name' (check host GPU + incus)"
}
[ "$need_fuse" = 1 ] && ensure_unix_char yx-dev-fuse /dev/fuse
for d in ${u_devs[@]+"${u_devs[@]}"}; do
  case "$d" in
    kvm)  ensure_unix_char yx-dev-kvm  /dev/kvm ;;
    fuse) ensure_unix_char yx-dev-fuse /dev/fuse ;;
    gpu)  ensure_gpu       yx-gpu ;;
    *)    warn "unknown YARD_DEVICE '$d' — skipping" ;;
  esac
done

# --- summary -----------------------------------------------------------------
echo
ok "Yard extras reconciled."
if [ "$restart_needed" = 1 ]; then
  warn "Capabilities changed — restart the yard to apply them (the host's network guard runs on the way up):"
  printf '    %s%s down && %s up%s\n' "$C_HEAD" "${PROG:-yard}" "${PROG:-yard}" "$C_OFF" >&2
fi
