#!/usr/bin/env bash
# project-sync.sh — bring a project into the yard, in one of two transports:
#   sync [path]  copy host project → /srv/workspaces/<id>/src (create-or-update).
#                First run registers state and copies; re-run re-copies (host → yard).
#                The host copy stays isolated; pull yard changes out with `yard export`.
#   bind [path]  mount the host folder into the yard via an Incus disk device — host
#                and yard share the same files (isolation reduced).
# A project is either sync or bind; switch modes with `yard remove` + re-add. Sync
# transport is a tar stream over `incus exec`. Operator-owned; no root.
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
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
mode="${1:-}"; shift || true
case "$mode" in sync | bind) ;; *) die "internal: mode must be sync|bind (got '$mode')" ;; esac
path="."
for a in "$@"; do
  case "$a" in
    -y | --yes) ;;  # handled by lib.sh (ASSUME_YES); ignore here
    -*)         die "unknown option '$a'" ;;
    *)          path="$a" ;;
  esac
done
[ -d "$path" ] || die "not a directory: $path"

# --- resolve identity --------------------------------------------------------
hostPath="$(realpath -- "$path")"
id="$(project_id "$hostPath")"
yardPath="$(yard_path_for "$id")"
name="$(basename -- "$hostPath")"

# A project is either sync or bind. Switching modes requires `yard remove` first.
if state_exists "$id"; then
  prev="$(state_get "$id" mode)"
  [ -n "$prev" ] && [ "$prev" != "$mode" ] \
    && die "'$name' is already in the yard as '$prev' — run: ${PROG:-yard} remove $path, then re-add as $mode"
fi

# --- preflight: yard must be running -----------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run setup first"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard setup' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it first (yard up)"

# --- bind: mount the host folder into the yard via an Incus disk device -------
# Host and yard share the same files (isolation reduced) — for trusted, hands-on
# work only. shift=true id-maps the mount so files show up owned by 'dev'.
if [ "$mode" = bind ]; then
  dev="$(ws_device_for "$id")"
  if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$dev"; then
    state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
    ok "bind already attached: $hostPath → $INSTANCE_NAME:$yardPath"
    info "id: $id"
    exit 0
  fi
  announce "yard bind — $name" \
    "Host source : $hostPath" \
    "Yard target : $yardPath (mode bind — host disk-mount, shared files)" \
    "Attach an Incus disk device (shift=true) so the yard sees this folder owned by 'dev'." \
    "Isolation is REDUCED: work in the yard writes straight to the host folder." \
    "Record machine-local state in $(state_file "$id")."
  proceed_or_die
  incus config device add "$INSTANCE_NAME" "$dev" disk "${PROJ[@]}" \
    source="$hostPath" path="$yardPath" shift=true >/dev/null \
    || die "could not attach bind mount (does the host kernel support idmapped/shifted mounts?)"
  state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
  ok "bind done: $hostPath ↔ $INSTANCE_NAME:$yardPath"
  info "id: $id"
  exit 0
fi

# --- sync: copy host → yard (create-or-update) -------------------------------
# First run registers state and copies; a re-run just re-copies (overwrites the yard copy).
state_exists "$id" && note="refresh the yard copy" || note="first copy into the yard"
announce "yard sync — $name" \
  "Host source : $hostPath" \
  "Yard target : $yardPath (mode sync — $note)" \
  "Copy the project into the yard via a tar stream (overwrites the yard copy)." \
  "Record machine-local state in $(state_file "$id")."
proceed_or_die

# Owned by 'dev' (DEV_UID) so the unpacked files belong to the in-yard user.
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- install -d -o "$DEV_UID" -g "$DEV_UID" "$yardPath" \
  || die "could not create $yardPath in the yard"
info "streaming $hostPath → $INSTANCE_NAME:$yardPath …"
tar -C "$hostPath" -cf - . \
  | incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" -- \
      tar -C "$yardPath" -xf - \
  || die "copy failed"

state_write "$id" "$name" "$hostPath" "$yardPath" sync "$SSH_HOST"
ok "sync done: $name → $yardPath"
info "id: $id"
