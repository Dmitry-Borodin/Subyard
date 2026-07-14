#!/usr/bin/env bash
# lib-service.sh — shared helpers for a PROFILE SHARED RESOURCE.
#
# A "profile shared resource" is a long-lived service that lives in the yard and is shared by
# the profile's agents: the android profile provides an *emulator*; the openclaw profile
# provides a *staging gateway* and a *QA bot-broker* (a leased pool of staging test-bots). They
# are the same idea — a resource a profile exposes, that its agents reach — but their mechanics
# differ (where it runs: L1 vs an L2 box; how agents reach it: an adb port-bridge vs the
# gateway's bot channel vs a loopback HTTP lease; arbitration: free-share vs a lease vs a pool;
# secrets: none vs staging creds + a prod-guard vs a host-seeded token pool). So a thin per-kind
# frontend owns those specifics (scripts/yard-emu.sh, project-staging.sh, qa-pool.sh).
#
# This lib carries ONLY what is genuinely common across kinds — the yard handle, the in-yard
# exec wrapper, the running-check, and the profile's resource declaration. It deliberately does
# NOT try to unify launch/bridge/arbitration; forcing those into one place would leak. Source
# it AFTER lib.sh (it uses incus_preflight/die from there).

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
_LIBSVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The profile shared-resource REGISTRY (descriptors under config/profiles/*/resources/*.res):
# discovery + dispatch + the up-probe delegation are all driven from there, so this lib carries
# NO per-resource knowledge.
# shellcheck source=scripts/lib-resources.sh
. "$_LIBSVC_DIR/lib-resources.sh"

# Run a command in the yard (as the instance's default user). The single in-yard exec wrapper
# shared by the service frontends; kind-specific interactive (-t) calls stay in each frontend.
yexec() { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }

# The yard must exist and be RUNNING before any resource verb. Uses lib.sh (incus_preflight/die).
svc_require_yard_running() {
  incus_preflight
  incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
    || die "instance '$INSTANCE_NAME' missing — run '$(yard_cmd_hint) init' first"
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: $(yard_cmd_hint) start"
}

# Resource NAMES a profile declares — its descriptors under config/profiles/<profile>/resources/.
# Echoes them one per line (may be empty). The registry (lib-resources.sh) is the single source;
# a frontend (named by the descriptor's HANDLER) maps each name to its own verbs.
svc_resources_for() { res_names_for_profile "$1"; }

# svc_resource_up <resource-name> — read-only probe: is a shared resource currently up? Delegates
# to the owning frontend's silent `is-up` verb (the handler knows its own "is it live?" signal —
# an adb port, a gateway pid, a running container), so this lib carries NO per-resource knowledge.
# Returns 0 (up) / 1 (down or unknown). Assumes the yard is RUNNING (caller checks); a frontend's
# is-up returns non-zero when the yard/resource is unreachable.
svc_resource_up() {
  local h; h="$(res_handler_for_name "$1" 2>/dev/null || true)"
  [ -n "$h" ] && [ -x "$_LIBSVC_DIR/$h" ] || return 1
  "$_LIBSVC_DIR/$h" is-up >/dev/null 2>&1
}

# svc_resource_hint <resource-name> — the operator command that brings this resource up, for a
# status hint next to a down resource (from the descriptor's COMMAND + BRINGUP). Empty if unknown.
svc_resource_hint() {
  local hint; hint="$(res_hint_for_name "$1" 2>/dev/null || true)"
  [ -n "$hint" ] && printf '%s' "$(yard_cmd_hint) $hint"
  # Explicit success: the trailing `[ -n … ] &&` above returns 1 for a resource with no hint, and
  # callers run under `set -e` — without this, an empty hint would abort the caller mid-status.
  return 0
}

# svc_resource_stop_hint <resource-name> — the operator command that stops an up resource.
svc_resource_stop_hint() {
  local hint; hint="$(res_stop_hint_for_name "$1" 2>/dev/null || true)"
  [ -n "$hint" ] && printf '%s' "$(yard_cmd_hint) $hint"
  return 0
}
