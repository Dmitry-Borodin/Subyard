#!/usr/bin/env bash
# project-state.sh — hidden owner-host endpoint used by a trusted remote controller to keep the
# owner host's machine-local project registry converged with successful remote sync/clone/remove
# operations. It never accepts a host path from the controller: a newly discovered project is
# recorded as yard-originated, while an existing owner-local hostPath is preserved.
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

valid_project_name() {
  [ -n "${1:-}" ] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\t'* ]]
}

action="${1:-}"; shift || true
case "$action" in
  upsert)
    [ "$#" -eq 4 ] || die "internal: _project-state upsert needs <id> <name> <mode> <target>"
    id="$1" name="$2" mode="$3" target="$4"
    state_project_id_valid "$id" || die "invalid project id"
    valid_project_name "$name" || die "invalid project name"
    state_project_mode_valid "$mode" || die "invalid project mode"
    state_project_target_valid "$target" || die "invalid project target"

    state_upsert_yard "$id" "$name" "$mode" "$target" "${SSH_HOST:-yard}"
    ;;
  unregister)
    [ "$#" -eq 1 ] || die "internal: _project-state unregister needs <id>"
    id="$1"
    state_project_id_valid "$id" || die "invalid project id"
    if state_exists "$id"; then
      # A foreign controller may remove only the synthetic owner record it created. Keep a
      # full owner-local record (non-empty hostPath); it remains a valid source for a future sync
      # and `yard list` will accurately report its yard copy as missing.
      host_path="$(state_get "$id" hostPath)"
      [ -n "$host_path" ] || state_remove "$id"
    fi
    ;;
  *) die "internal: _project-state expects upsert or unregister" ;;
esac
