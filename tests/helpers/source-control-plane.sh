#!/usr/bin/env bash
# Test-only composition of prepared physical adapters.

CONTROL_PLANE_ROOT="${CONTROL_PLANE_ROOT:?set CONTROL_PLANE_ROOT before sourcing}"
# shellcheck source=scripts/lib/runtime.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/runtime.sh"
# shellcheck source=scripts/lib/engine-context.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/engine-context.sh"
subyard_require_engine_context
# shellcheck source=scripts/lib/ui.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/ui.sh"
# shellcheck source=scripts/lib-power.sh
. "$CONTROL_PLANE_ROOT/scripts/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/host.sh"
