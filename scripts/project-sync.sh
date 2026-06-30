#!/usr/bin/env bash
# project-sync.sh — bring a project into the yard:
#   sync [path]  copy host project → /srv/workspaces/<id>/src (create-or-update; pull back via `yard export`)
#   bind [path]  mount the host folder into the yard (shared files, isolation reduced)
# One mode per project; switch with `yard remove` + re-add. Sync transport: rsync over ssh
# (tar-over-`incus exec` fallback). Operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
# TARGET (orthogonal to sync/bind): `yard` = L1, a profile name = L2 box. Default `yard`;
# unset on re-add keeps the stored value.
mode="${1:-}"; shift || true
case "$mode" in sync | bind) ;; *) die "internal: mode must be sync|bind (got '$mode')" ;; esac
path="."; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   target="${2:?--target needs yard|<profile>}"; shift ;;
    --target=*) target="${1#*=}" ;;
    -y | --yes) ;;  # handled by lib.sh (ASSUME_YES); ignore here
    -*)         die "unknown option '$1'" ;;
    *)          path="$1" ;;
  esac
  shift
done
[ -d "$path" ] || die "not a directory: $path"

# --- resolve identity --------------------------------------------------------
hostPath="$(realpath -- "$path")"
id="$(project_id "$hostPath")"
yardPath="$(yard_path_for "$id")"
name="$(basename -- "$hostPath")"

# --- resolve & validate target (L1 `yard` vs L2 profile box) -----------------
# Unset → stored target, else `yard`; a non-yard value must be a profile under config/profiles/.
if [ -z "$target" ]; then
  state_exists "$id" && target="$(state_get "$id" target)"
  [ -n "$target" ] || target="yard"
fi
if [ "$target" != yard ]; then
  [ -r "$PROFILES_DIR/$target/profile.conf" ] || die "unknown --target '$target' — use 'yard' (L1) or a profile (L2): $(for d in "$PROFILES_DIR"/*/; do [ -r "$d/profile.conf" ] && basename "$d"; done | tr '\n' ' ')"
fi
[ "$target" = yard ] && target_note="L1 — runs in the yard directly" || target_note="L2 — project-env box from profile '$target' (bring up: ${PROG:-yard} up $path)"

if state_exists "$id"; then
  prev="$(state_get "$id" mode)"
  [ -n "$prev" ] && [ "$prev" != "$mode" ] \
    && die "'$name' is already in the yard as '$prev' — run: ${PROG:-yard} remove $path, then re-add as $mode"
fi

# --- preflight: yard must be running -----------------------------------------
incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it first (yard start)"

# --- bind: mount the host folder via an Incus disk device (shared files; shift=true → owned by 'dev')
if [ "$mode" = bind ]; then
  dev="$(ws_device_for "$id")"
  if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$dev"; then
    state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
    state_set "$id" target "$target"
    ok "bind already attached: $hostPath → $INSTANCE_NAME:$yardPath (target $target)"
    info "id: $id"
    exit 0
  fi
  announce "yard bind — $name" \
    "Host source : $hostPath" \
    "Yard target : $yardPath (mode bind — host disk-mount, shared files)" \
    "Run target  : $target_note" \
    "Attach an Incus disk device (shift=true) so the yard sees this folder owned by 'dev'." \
    "Isolation is REDUCED: work in the yard writes straight to the host folder." \
    "Record machine-local state in $(state_file "$id")."
  proceed_or_die
  incus config device add "$INSTANCE_NAME" "$dev" disk "${PROJ[@]}" \
    source="$hostPath" path="$yardPath" shift=true >/dev/null \
    || die "could not attach bind mount (does the host kernel support idmapped/shifted mounts?)"
  state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
  state_set "$id" target "$target"
  ok "bind done: $hostPath ↔ $INSTANCE_NAME:$yardPath (target $target)"
  info "id: $id"
  exit 0
fi

# --- sync: copy host → yard (create-or-update) -------------------------------
state_exists "$id" && note="refresh the yard copy" || note="first copy into the yard"
announce "yard sync — $name" \
  "Host source : $hostPath" \
  "Yard target : $yardPath (mode sync — $note)" \
  "Run target  : $target_note" \
  "Copy the project into the yard via rsync over ssh (incremental; updates, no deletes)." \
  "Record machine-local state in $(state_file "$id")."
proceed_or_die

# Pre-create the dest owned by 'dev' (root op; rsync then writes as the unprivileged dev user).
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- install -d -o "$DEV_UID" -g "$DEV_UID" "$yardPath" \
  || die "could not create $yardPath in the yard"

# rsync over ssh (incremental). No --delete: agents build in the yard, so yard-only files
# (node_modules, build output) survive. Falls back to a tar stream over `incus exec` if ssh is down.
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" true 2>/dev/null; then
  info "rsync $hostPath → $SSH_HOST:$yardPath …"
  rsync -a -e ssh "$hostPath/" "$SSH_HOST:$yardPath/" || die "rsync failed"
else
  info "ssh '$SSH_HOST' unavailable — tar stream over incus exec …"
  tar -C "$hostPath" -cf - . \
    | incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" -- \
        tar -C "$yardPath" -xf - \
    || die "copy failed"
fi

state_write "$id" "$name" "$hostPath" "$yardPath" sync "$SSH_HOST"
state_set "$id" target "$target"
ok "sync done: $name → $yardPath (target $target)"
info "id: $id"
