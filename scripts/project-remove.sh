#!/usr/bin/env bash
# project-remove.sh — take a project out of the yard.
# Usage: project-remove.sh [path] [--soft]
#   (default)  full removal: drop the machine-local state AND delete the yard copy
#              at /srv/workspaces/<id> (bind projects: host files are never touched)
#   --soft     keep the yard copy; only drop the state and the L2 project-env box
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
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
# Resolve the project: a host directory → hash its realpath (sync/bind); otherwise the
# argument is a project id or name (git-mode clones have no host path to hash).
if [ -d "$path" ]; then
  id="$(project_id "$path")"
elif state_exists "$path"; then
  id="$path"
else
  id=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ "$(state_get "$cand" name)" = "$path" ] && { id="$cand"; break; }
  done < <(state_ids)
  [ -n "$id" ] || die "no such path, project id, or name: $path"
fi
state_exists "$id" || die "not in the yard: $path"
name="$(state_get "$id" name)"
yardPath="$(state_get "$id" yardPath)"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>
mode="$(state_get "$id" mode)"
target="$(state_get "$id" target)"
box_cname="subyard-box-$id"   # matches cname_for() in project-env.sh
running() { [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; }

# Remove the project's L2 project-env box (if any) and its staged secrets/manifest.
# Best-effort: a project that runs in L1 (target=yard) has no box — this no-ops.
remove_box() {
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
    "Drop machine-local state: $(state_file "$id")." \
    "Remove its L2 project-env box if present (target=${target:-yard})." \
    "Leave the yard copy at $yardDir in place (re-add it later with 'yard sync'/'yard clone')."
else
  # Fail BEFORE dropping state: once the state is gone the copy can no longer be
  # resolved by name, and it would be orphaned in the yard.
  running || die "yard is down — start it ('yard start') to delete the yard copy, or re-run with --soft to keep it"
  announce "yard remove — $name" \
    "Drop machine-local state: $(state_file "$id")." \
    "Remove its L2 project-env box if present (target=${target:-yard})." \
    "DELETE the yard copy: $INSTANCE_NAME:$yardDir (irreversible; use --soft to keep it)."
fi
proceed_or_die
remove_box

if [ "$soft" = 0 ]; then
  case "$yardDir" in
    /srv/workspaces/?*) incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "$yardDir" \
      && ok "deleted $yardDir" ;;
    *) die "refusing to delete unexpected path '$yardDir'" ;;
  esac
fi

state_remove "$id"
[ "$soft" = 1 ] && ok "removed '$name' from the yard (yard copy kept)" || ok "removed '$name' from the yard (yard copy deleted)"
