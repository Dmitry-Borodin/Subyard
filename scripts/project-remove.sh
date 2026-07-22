#!/usr/bin/env bash
# project-remove.sh — take a project out of the yard.
# Usage: project-remove.sh [path] [--soft]
#   (default)  full removal: drop the machine-local state AND delete the yard copy
#              at /srv/workspaces/<id> (bind projects: host files are never touched)
#   --soft     keep the yard copy; only drop the state and the L2 project-env box
# Remote yards (YARD_TYPE=remote): no local incus — reachability is an ssh probe, the in-yard
# copy is deleted over the yard-<name> alias (`rm -rf`, as dev), and an L2 box is torn down by
# asking the owner host to execute inside its yard. A project found only in the yard (no local
# record) is registered on demand from its meta so it can still be removed.
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
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
# shellcheck source=scripts/state/transport.sh
. "$SCRIPT_DIR/state/transport.sh"
# shellcheck source=scripts/state/metadata.sh
. "$SCRIPT_DIR/state/metadata.sh"
# shellcheck source=scripts/lib/project-snapshot.sh
. "$SCRIPT_DIR/lib/project-snapshot.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"   # remote yards delete the in-yard copy over this alias
PROJ=(--project "$INCUS_PROJECT")

soft=0
for a in "$@"; do
  case "$a" in
    --soft)      soft=1 ;;
    --purge)     warn "--purge is deprecated: full removal is the default now (--soft keeps the copy)" ;;
    -y|--yes)    ;;  # handled by ui.sh
    -*)          die "unknown option '$a'" ;;
    *)           : ;;
  esac
done
project_snapshot_load
yard="${YARD_NAME:-default}"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>
box_cname="subyard-box-$id"   # matches cname_for() in project-env.sh
# Reachability: a local yard is "running" when incus says so; a remote yard when its ssh
# alias answers (no local incus). Every call site below routes through this.
running() {
  if yard_is_remote; then yard_reachable; else
    [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; fi
}

# Remove the project's L2 project-env box (if any) and its staged secrets/manifest. L1 projects
# have no L2 resources and return silently. For a remote L2 project this is a hard prerequisite:
# any owner-side failure stops removal before either the workspace or controller state is deleted.
remove_box() {
  [ "${target:-yard}" != yard ] || return 0
  if yard_is_remote; then
    local cleanup_script
    cleanup_script='id=$1
case "$id" in ""|-*|*[!A-Za-z0-9._-]*) exit 64;; esac
box="subyard-box-$id"
docker info >/dev/null
if docker inspect "$box" >/dev/null 2>&1; then docker rm -f "$box" >/dev/null; fi
rm -rf -- "/srv/env-secrets/$id" "/srv/env-meta/$id"'
    remote_owner_yard_cmd shell --root -- sh -eu -c "$cleanup_script" _ "$id" \
      || die "could not remove L2 box/staged env for '$name' on the owner host; project state and workspace were kept"
    ok "removed remote L2 box/staged env for '$name'"
    return 0
  fi
  running || return 0
  if incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- docker inspect "$box_cname" >/dev/null 2>&1; then
    incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- docker rm -f "$box_cname" >/dev/null 2>&1 \
      && ok "removed L2 box '$box_cname'"
  fi
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "/srv/env-secrets/$id" "/srv/env-meta/$id" 2>/dev/null || true
}

# --- bind: detach the disk device; NEVER delete (the source is the host folder) ----
if [ "$mode" = bind ]; then
  remove_details=(
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state through the Go control plane.")
  [ "${target:-yard}" = yard ] || remove_details+=("Remove its L2 project-env box and staged env (target=$target); workspace/caches kept.")
  remove_details+=(
    "Detach the bind mount '$dev' from the yard. The host folder $yardPath is untouched."
  )
  announce "yard remove — $name (bind)" "${remove_details[@]}"
  proceed_or_die
  remove_box
  if running; then
    if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$dev"; then
      incus config device remove "$INSTANCE_NAME" "$dev" "${PROJ[@]}" >/dev/null \
        && ok "detached bind mount '$dev'"
    else
      warn "no bind device '$dev' attached — nothing to detach"
    fi
  else
    warn "yard is down — leaving the device entry; it detaches on next start or re-run when up"
  fi
  ok "removed '$name' from the yard (bind detached; host files kept)"
  exit 0
fi

# --- sync/clone: delete the yard copy unless --soft --------------------------
if [ "$soft" = 1 ]; then
  remove_details=(
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state through the Go control plane.")
  [ "${target:-yard}" = yard ] || remove_details+=("Remove its L2 project-env box and staged env (target=$target).")
  remove_details+=(
    "Leave the yard copy at $yardDir in place (re-add it later with 'yard sync'/'yard clone')."
  )
  announce "yard remove --soft — $name" "${remove_details[@]}"
else
  # Fail BEFORE dropping state: once the state is gone the copy can no longer be
  # resolved by name, and it would be orphaned in the yard.
  if yard_is_remote; then
    require_remote_reachable
  elif ! running; then
    die "yard is down — start it ('yard start') to delete the yard copy, or re-run with --soft to keep it"
  fi
  remove_details=(
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state through the Go control plane.")
  [ "${target:-yard}" = yard ] || remove_details+=("Remove its L2 project-env box and staged env (target=$target).")
  remove_details+=(
    "DELETE the yard copy: $INSTANCE_NAME:$yardDir (irreversible; use --soft to keep it)."
  )
  announce "yard remove — $name" "${remove_details[@]}"
fi
proceed_or_die
remove_box

if [ "$soft" = 0 ]; then
  case "$yardDir" in
    /srv/workspaces/?*)
      if yard_is_remote; then
        # dev owns the sync/clone trees in the yard, so delete over the alias (no local incus).
        ssh "$SSH_HOST" -- rm -rf "$yardDir" && ok "deleted $yardDir"
      else
        incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "$yardDir" && ok "deleted $yardDir"
      fi ;;
    *) die "refusing to delete unexpected path '$yardDir'" ;;
  esac
fi

[ "$soft" = 1 ] && ok "removed '$name' from the yard (yard copy kept)" || ok "removed '$name' from the yard (yard copy deleted)"
