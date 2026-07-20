#!/usr/bin/env bash
# Test-only explicit composition of the credential domain and production adapters.

CONTROL_PLANE_ROOT="${CONTROL_PLANE_ROOT:?set CONTROL_PLANE_ROOT before sourcing}"
SCRIPT_DIR="${SCRIPT_DIR:-$CONTROL_PLANE_ROOT/scripts}"
# shellcheck source=scripts/credentials/store.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/store.sh"
# shellcheck source=scripts/credentials/crypto.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/crypto.sh"
# shellcheck source=scripts/credentials/domain.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/domain.sh"
# shellcheck source=scripts/credentials/revision-adapter.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/revision-adapter.sh"
# shellcheck source=scripts/credentials/policy.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/policy.sh"
# shellcheck source=scripts/credentials/sync-state.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/sync-state.sh"
# shellcheck source=scripts/credentials/transport.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/transport.sh"
# shellcheck source=scripts/credentials/materialize.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/materialize.sh"
# shellcheck source=scripts/credentials/verification.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/verification.sh"
# shellcheck source=scripts/credentials/peers.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/peers.sh"
# shellcheck source=scripts/credentials/sync.sh
. "$CONTROL_PLANE_ROOT/scripts/credentials/sync.sh"
