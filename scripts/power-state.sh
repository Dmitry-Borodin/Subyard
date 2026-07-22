#!/usr/bin/env bash
# power-state.sh — internal per-yard desired-power migration/finalization helper.
# Called by `yard init`; use public `yard start|stop|status` for normal lifecycle changes.
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
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
YARD_LABEL="${YARD_NAME:-default}"
PROJ=(--project "$INCUS_PROJECT")

instance_exists() {
  command -v incus >/dev/null 2>&1 \
    && incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1
}

is_remote() { [ "${YARD_TYPE:-local}" = remote ]; }

import_current() {
  is_remote && return 0
  instance_exists || return 0
  power_import_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
    || die "$POWER_ERROR"
  if [ "$POWER_IMPORTED" = 1 ]; then
    ok "imported $YARD_LABEL power state: $(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
  fi
}

needs_import_current() {
  is_remote && return 1
  instance_exists || return 1
  [ "$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_MANAGED")" != true ]
}

for_each_registered() { # <needs-import|import-current>
  local verb="$1" name rc
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if SUBYARD_YARD="$name" "$SCRIPT_DIR/power-state.sh" "$verb"; then rc=0; else rc=$?; fi
    if [ "$verb" = needs-import ] && [ "$rc" = 0 ]; then return 0; fi
    [ "$verb" = needs-import ] || [ "$rc" = 0 ] || return "$rc"
  done < <(yard_registry_names)
  [ "$verb" != needs-import ]
}

case "${1:-}" in
  import-current) import_current ;;
  needs-import) needs_import_current ;;
  import-all) for_each_registered import-current ;;
  needs-import-any) for_each_registered needs-import ;;
  finalize)
    is_remote && die "remote yard power state is owned by its remote host"
    instance_exists || die "instance '$INSTANCE_NAME' is missing"
    power_finalize_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
      || die "$POWER_ERROR"
    ok "$YARD_LABEL desired power is $(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
    ;;
  ready)
    is_remote && exit 0
    instance_exists || exit 1
    power_metadata_ready "$INCUS_PROJECT" "$INSTANCE_NAME" "$BRIDGE"
    ;;
  *) die "internal usage: power-state.sh import-all|import-current|needs-import-any|needs-import|finalize|ready" ;;
esac
