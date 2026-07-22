#!/usr/bin/env bash
# Test-only explicit composition of the production source-only control-plane modules.

CONTROL_PLANE_ROOT="${CONTROL_PLANE_ROOT:?set CONTROL_PLANE_ROOT before sourcing}"
# shellcheck source=scripts/lib/runtime.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib-power.sh
. "$CONTROL_PLANE_ROOT/scripts/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$CONTROL_PLANE_ROOT/scripts/lib/host.sh"
