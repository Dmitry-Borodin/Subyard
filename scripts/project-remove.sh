#!/usr/bin/env bash
# project-remove.sh — take a project out of the yard.
# Usage: project-remove.sh [path] [--soft]
#   (default)  full removal: drop the machine-local state AND delete the yard copy
#              at /srv/workspaces/<id> (bind projects: host files are never touched)
#   --soft     keep the yard copy; only drop the state and the L2 project-env box
# Remote yards (YARD_TYPE=remote): no local incus — reachability is an ssh probe, the in-yard
# copy is deleted over the yard-<name> alias (`rm -rf`, as dev), and L2 box teardown is skipped
# (boxes are managed on the owner host). A project found only in the yard (no local record) is
# registered on demand from its meta so it can still be removed.
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"   # remote yards delete the in-yard copy over this alias
PROJ=(--project "$INCUS_PROJECT")

path="."; soft=0
for a in "$@"; do
  case "$a" in
    --soft)      soft=1 ;;
    --purge)     warn "--purge is deprecated: full removal is the default now (--soft keeps the copy)" ;;
    -y|--yes)    ;;  # handled by lib.sh
    -*)          die "unknown option '$a'" ;;
    *)           path="$a" ;;
  esac
done
# Resolve the project (path, exact id, or name — git-mode clones have no host path to hash).
# maybe_reconcile registers on demand a project that lives only in the yard (explicit context)
# so it can be removed; resolve_project_ctx then resolves across yards and re-execs in the owner.
maybe_reconcile "$path"
resolve_project_ctx "$path"
id="$RESOLVED_ID"
yard="${YARD_NAME:-default}"
name="$(state_get "$id" name)"
hostPath="$(state_get "$id" hostPath)"
yardPath="$(state_get "$id" yardPath)"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>
mode="$(state_get "$id" mode)"
target="$(state_get "$id" target)"
box_cname="subyard-box-$id"   # matches cname_for() in project-env.sh
# Reachability: a local yard is "running" when incus says so; a remote yard when its ssh
# alias answers (no local incus). Every call site below routes through this.
running() {
  if yard_is_remote; then yard_reachable; else
    [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; fi
}

# Remove the project's L2 project-env box (if any) and its staged secrets/manifest.
# Best-effort: a project that runs in L1 (target=yard) has no box — this no-ops. Remote yards
# manage their boxes on the owner host, so there is nothing to tear down from here.
remove_box() {
  if yard_is_remote; then
    warn "L2 project-env boxes are managed on the yard's owner host — skipping box teardown"
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
  dev="$(ws_device_for "$id")"
  announce "yard remove — $name (bind)" \
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state: $(state_file "$id")." \
    "Remove its L2 project-env box if present (target=${target:-yard}); workspace/caches kept." \
    "Detach the bind mount '$dev' from the yard. The host folder $yardPath is untouched."
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
  state_remove "$id"
  ok "removed '$name' from the yard (bind detached; host files kept)"
  exit 0
fi

# --- sync/clone: delete the yard copy unless --soft --------------------------
if [ "$soft" = 1 ]; then
  announce "yard remove --soft — $name" \
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state: $(state_file "$id")." \
    "Remove its L2 project-env box if present (target=${target:-yard})." \
    "Leave the yard copy at $yardDir in place (re-add it later with 'yard sync'/'yard clone')."
else
  # Fail BEFORE dropping state: once the state is gone the copy can no longer be
  # resolved by name, and it would be orphaned in the yard.
  if yard_is_remote; then
    require_remote_reachable
  elif ! running; then
    die "yard is down — start it ('yard start') to delete the yard copy, or re-run with --soft to keep it"
  fi
  announce "yard remove — $name" \
    "Yard      : $yard    Host path: $hostPath" \
    "Drop machine-local state: $(state_file "$id")." \
    "Remove its L2 project-env box if present (target=${target:-yard})." \
    "DELETE the yard copy: $INSTANCE_NAME:$yardDir (irreversible; use --soft to keep it)."
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

state_remove "$id"
[ "$soft" = 1 ] && ok "removed '$name' from the yard (yard copy kept)" || ok "removed '$name' from the yard (yard copy deleted)"
