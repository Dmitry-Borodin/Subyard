#!/usr/bin/env bash
# project-remove.sh — take a project out of the yard.
# Usage: project-remove.sh [path] [--purge]
#   (default)  drop the machine-local state; leaves the yard copy in place
#   --purge    also delete the yard copy at /srv/workspaces/<id>
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

path="."; purge=0
for a in "$@"; do
  case "$a" in
    --purge)     purge=1 ;;
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
running() { [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; }

# --- bind: detach the disk device; NEVER delete (the source is the host folder) ----
if [ "$mode" = bind ]; then
  dev="$(ws_device_for "$id")"
  [ "$purge" = 1 ] && warn "'$name' is a bind project — --purge does NOT delete host files; only detaching the mount"
  announce "yard remove — $name (bind)" \
    "Drop machine-local state: $(state_file "$id")." \
    "Detach the bind mount '$dev' from the yard. The host folder $yardPath is untouched."
  proceed_or_die
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

# --- sync: optionally delete the yard copy -----------------------------------
if [ "$purge" = 1 ]; then
  announce "yard remove --purge — $name" \
    "Drop machine-local state: $(state_file "$id")." \
    "DELETE the yard copy: $INSTANCE_NAME:$yardDir (irreversible)."
else
  announce "yard remove — $name" \
    "Drop machine-local state: $(state_file "$id")." \
    "Leave the yard copy at $yardDir in place (use --purge to delete it)."
fi
proceed_or_die

if [ "$purge" = 1 ]; then
  if running; then
    case "$yardDir" in
      /srv/workspaces/?*) incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "$yardDir" \
        && ok "deleted $yardDir" ;;
      *) die "refusing to delete unexpected path '$yardDir'" ;;
    esac
  else
    warn "yard is down — skipping copy deletion (start it and re-run --purge)"
  fi
fi

state_remove "$id"
[ "$purge" = 1 ] && ok "removed '$name' from the yard (purged)" || ok "removed '$name' from the yard"
