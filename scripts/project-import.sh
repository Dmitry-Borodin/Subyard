#!/usr/bin/env bash
# project-import.sh — Phase 7b (slice): bring a project into the yard, sync mode.
# Usage: project-import.sh <import|sync> [path] [--bind]
#   import [path]  copy host project → /srv/workspaces/<id>/src (default path '.')
#   sync   [path]  re-copy an already-imported project (host → yard)
# Sync = copy, so the agent never writes back to the host folder (isolation kept).
# Transport is a tar stream over `incus exec` (no ssh-proxy needed yet); a later
# pass can switch to rsync for incremental/delete-aware sync. Operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
action="${1:-}"; shift || true
case "$action" in import | sync) ;; *) die "internal: action must be import|sync (got '$action')" ;; esac
path="."; bind=0
for a in "$@"; do
  case "$a" in
    --bind)            bind=1 ;;
    -y | --yes)        ;;  # handled by lib.sh (ASSUME_YES); ignore here
    -*)                die "unknown option '$a'" ;;
    *)                 path="$a" ;;
  esac
done
[ -d "$path" ] || die "not a directory: $path"

# --- resolve identity --------------------------------------------------------
hostPath="$(realpath -- "$path")"
id="$(project_id "$hostPath")"
yardPath="$(yard_path_for "$id")"
name="$(basename -- "$hostPath")"

# A project is either sync or bind; the two transports are incompatible. Re-importing
# with a different mode would silently mix them, so make the operator remove first.
if state_exists "$id"; then
  prev="$(state_get "$id" mode)"
  want=sync; [ "$bind" = 1 ] && want=bind
  [ -n "$prev" ] && [ "$prev" != "$want" ] \
    && die "'$name' is already imported as '$prev' — run: ${PROG:-yard} remove $path, then re-import as $want"
fi

if [ "$action" = sync ]; then
  state_exists "$id" || die "'$name' is not imported yet — run: ${PROG:-yard} import $path"
  [ "$(state_get "$id" mode)" = bind ] \
    && die "'$name' is a bind project — its files live on the host already; 'sync' does not apply"
fi

# --- preflight: yard must be running -----------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run setup first"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard setup' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it first (yard up)"

# --- bind: mount the host folder into the yard via an Incus disk device -------
# No copy: edits on the host and in the yard are the same files. Isolation is
# reduced (the agent writes the host folder) — for trusted, hands-on work only.
# shift=true id-maps the mount so the files show up owned by 'dev', not nobody.
if [ "$bind" = 1 ]; then
  dev="$(ws_device_for "$id")"
  if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$dev"; then
    state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
    ok "bind already attached: $hostPath → $INSTANCE_NAME:$yardPath"
    info "id: $id"
    exit 0
  fi
  announce "yard import --bind — $name" \
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

# --- sync: copy host → yard --------------------------------------------------
announce "yard $action — $name" \
  "Host source : $hostPath" \
  "Yard target : $yardPath (mode sync)" \
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
ok "$action done: $name → $yardPath"
info "id: $id"
