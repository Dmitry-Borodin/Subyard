#!/usr/bin/env bash
# project-sync.sh — bring a project into the yard:
#   sync [path] [@yard]  copy host project → /srv/workspaces/<id>/src (create-or-update; pull back via `yard export`)
#   bind [path] [@yard]  mount the host folder into the yard (shared files, isolation reduced)
# One mode per project; switch with `yard remove` + re-add. Sync transport: rsync over ssh
# (tar-over-`incus exec` fallback for a LOCAL yard only). Operator-owned; no root.
#
# Remote yards (YARD_TYPE=remote): no local incus — reachability is an ssh probe over the
# yard-<name> ProxyJump alias, the dest is pre-created over ssh, and the copy is rsync over
# that alias. `bind` is refused (the host path does not exist on the remote yard). A yard-side
# .subyard-meta.json is written on success for local AND remote yards (best-effort).
#
# Yard addressing (multi-yard): with no -Y/@ context the target follows the path — a first sync
# stays in the default yard, a re-sync routes to the yard already holding it. A trailing `@<yard>`
# picks the target for a FIRST sync/bind (like -Y <yard>); a path in two+ yards is ambiguous and dies.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=scripts/state/store.sh
. "$SCRIPT_DIR/state/store.sh"
# shellcheck source=scripts/state/resolver.sh
. "$SCRIPT_DIR/state/resolver.sh"
# shellcheck source=scripts/state/transport.sh
. "$SCRIPT_DIR/state/transport.sh"
# shellcheck source=scripts/state/metadata.sh
. "$SCRIPT_DIR/state/metadata.sh"
state_validate_all || die "project state validation failed"

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
path="."; target=""; at_yard=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   target="${2:?--target needs yard|<profile>}"; shift ;;
    --target=*) target="${1#*=}" ;;
    -y | --yes) ;;  # handled by ui.sh (ASSUME_YES); ignore here
    @?*)        at_yard="${1#@}" ;;  # trailing `@<yard>` — target yard (first sync/bind)
    -*)         die "unknown option '$1'" ;;
    *)          path="$1" ;;
  esac
  shift
done
[ -d "$path" ] || die "not a directory: $path"
# --- resolve identity --------------------------------------------------------
hostPath="$(realpath -- "$path")"
if [ "$mode" = bind ]; then
  warn "explicit bind exposes the host path directly to the yard: $hostPath"
  warn "encapsulation is reduced; yard processes can read and modify everything permitted by that mount"
fi
id="$(project_id "$hostPath")"
yardPath="$(yard_path_for "$id")"
name="$(basename -- "$hostPath")"

# --- route to the target yard (multi-yard) -----------------------------------
# Pick the yard from `@<yard>` or the path's existing registration and re-exec there if it is not
# the loaded context. Everything below then runs in the correct yard's STATE_DIR. (See route_sync_target.)
route_sync_target "$id" "$at_yard"

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

# --- bind is host-local: a remote yard has no such host path (dispatcher already refuses;
#     defend here too so a direct script call fails with the same clear message). ------------
if yard_is_remote && [ "$mode" = bind ]; then
  die "bind is host-local — use sync or clone (a bind mounts a host path that does not exist on the remote yard)"
fi

# --- preflight: yard must be reachable ---------------------------------------
# Remote: probe the ssh alias (never incus). Local: incus daemon + instance RUNNING.
if yard_is_remote; then
  require_remote_reachable
else
  incus_preflight
  incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
    || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it first (yard start)"
fi

# --- bind: mount the host folder via an Incus disk device (shared files; shift=true → owned by 'dev')
if [ "$mode" = bind ]; then
  dev="$(ws_device_for "$id")"
  if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$dev"; then
    state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
    state_set "$id" target "$target"
    write_yard_meta "$id" "$name" bind "$target"   # so `list --live` shows it (bind is local-only)
    ok "bind already attached: $hostPath → $INSTANCE_NAME:$yardPath (target $target)"
    info "id: $id"
    exit 0
  fi
  announce "yard bind — $name" \
    "Host source : $hostPath" \
    "Yard target : $yardPath (mode bind — host disk-mount, shared files)" \
    "Run target  : $target_note" \
    "Attach an Incus disk device (shift=true) so the yard sees this folder owned by 'dev'." \
    "Encapsulation is REDUCED: the selected host path is directly readable/writable from the yard." \
    "This is explicit operator authority, not a Subyard-managed HOST_BASE mount." \
    "Record machine-local state in $(state_file "$id")."
  proceed_or_die
  incus config device add "$INSTANCE_NAME" "$dev" disk "${PROJ[@]}" \
    source="$hostPath" path="$yardPath" shift=true >/dev/null \
    || die "could not attach bind mount (does the host kernel support idmapped/shifted mounts?)"
  state_write "$id" "$name" "$hostPath" "$yardPath" bind "$SSH_HOST"
  state_set "$id" target "$target"
  # Yard-side meta (best-effort) — bind exits before the sync path's write_yard_meta, so without
  # this a bind project shows `missing` under `yard list --live`. Bind is local-only.
  write_yard_meta "$id" "$name" bind "$target"
  ok "bind done: $hostPath ↔ $INSTANCE_NAME:$yardPath (target $target)"
  info "id: $id"
  exit 0
fi

# --- sync: copy host → yard (create-or-update) -------------------------------
state_exists "$id" && note="refresh the yard copy" || note="first copy into the yard"
sync_details=(
  "Host source : $hostPath" \
  "Yard target : $yardPath (mode sync — $note)" \
  "Run target  : $target_note" \
  "Copy the project into the yard via rsync over ssh (incremental; updates, no deletes).")
if yard_is_remote; then
  sync_details+=("The remote owner host can read everything copied from this resolved source: $hostPath.")
fi
sync_details+=(
  "Record machine-local state in $(state_file "$id")."
)
announce "yard sync — $name" "${sync_details[@]}"
proceed_or_die

# Pre-create the dest owned by 'dev'. Local: a root incus op then chowns to dev. Remote: no
# local incus — create it over ssh (the alias logs in as dev, so the tree is dev-owned).
if yard_is_remote; then
  ssh "$SSH_HOST" -- install -d "$yardPath" \
    || die "could not create $yardPath in the remote yard"
else
  # -o/-g apply only to the LEAF dir; name the project dir explicitly too, or it is left
  # root-owned and dev can neither write next to src/ (yard meta) nor remove the tree over ssh.
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- \
    install -d -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$yardPath")" "$yardPath" \
    || die "could not create $yardPath in the yard"
fi

# rsync over ssh (incremental). No --delete: agents build in the yard, so yard-only files
# (node_modules, build output) survive. A LOCAL yard probes ssh to choose rsync vs a tar-over-
# `incus exec` fallback; a REMOTE yard has no fallback and its reachability was already proven by
# the `install -d` above, so it goes straight to rsync (skip the redundant probe).
if yard_is_remote || ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" true 2>/dev/null; then
  info "rsync $hostPath → $SSH_HOST:$yardPath …"
  rsync -a -e ssh "$hostPath/" "$SSH_HOST:$yardPath/" || die "rsync failed"
else
  info "ssh '$SSH_HOST' unavailable — tar stream over incus exec …"
  tar -C "$hostPath" -cf - . \
    | incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" -- \
        tar -C "$yardPath" -xf - \
    || die "copy failed"
fi

# Write portable yard metadata first. For a remote yard, then make owner-host registration part
# of the successful operation; only after that publish this controller's local record. This order
# leaves a failed owner update safely rerunnable instead of claiming a fully completed sync.
write_yard_meta "$id" "$name" sync "$target"
if yard_is_remote; then
  remote_owner_project_upsert "$id" "$name" sync "$target" \
    || die "project copied, but the owner-host registry was not updated; re-run the same sync command"
fi
state_write "$id" "$name" "$hostPath" "$yardPath" sync "$SSH_HOST"
state_set "$id" target "$target"
ok "sync done: $name → $yardPath (target $target)"
info "id: $id"
