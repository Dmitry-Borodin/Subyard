#!/usr/bin/env bash
# project-remove.sh — take a project out of the yard.
# Usage: project-remove.sh [path] [--purge]
#   (default)  drop the machine-local state; leaves the yard copy in place
#   --purge    also delete the yard copy at /srv/workspaces/<id>
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env.
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
[ -e "$path" ] || die "no such path: $path"

id="$(project_id "$path")"
state_exists "$id" || die "not imported: $(basename "$(realpath "$path")")"
name="$(state_get "$id" name)"
yardPath="$(state_get "$id" yardPath)"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>

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
  if [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; then
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
