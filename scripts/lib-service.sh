#!/usr/bin/env bash
# lib-service.sh — shared helpers for a PROFILE SHARED RESOURCE.
#
# A "profile shared resource" is a long-lived service that lives in the yard and is shared by
# the profile's agents: the android profile provides an *emulator*; the openclaw profile
# provides a *staging gateway*. Both are the same idea — a resource a profile exposes, that its
# agents reach — but their mechanics differ (where it runs: L1 vs an L2 box; how agents reach
# it: an adb port-bridge vs the gateway's own bot channel; arbitration: free-share vs a lease;
# secrets: none vs staging creds + a prod-guard). So a thin per-kind frontend owns those
# specifics (scripts/yard-emu.sh, scripts/project-staging.sh).
#
# This lib carries ONLY what is genuinely common across kinds — the yard handle, the in-yard
# exec wrapper, the running-check, and the profile's resource declaration. It deliberately does
# NOT try to unify launch/bridge/arbitration; forcing those into one place would leak. Source
# it AFTER lib.sh (it uses incus_preflight/die from there).

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")

# Run a command in the yard (as the instance's default user). The single in-yard exec wrapper
# shared by the service frontends; kind-specific interactive (-t) calls stay in each frontend.
yexec() { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }

# The yard must exist and be RUNNING before any resource verb. Uses lib.sh (incus_preflight/die).
svc_require_yard_running() {
  incus_preflight
  incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
    || die "instance '$INSTANCE_NAME' missing — run '${PROG:-yard} init' first"
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: ${PROG:-yard} start"
}

# Shared resources a profile declares, via SHARED_RESOURCES in its profile.conf (space-separated
# names, e.g. "emulator" / "staging-gateway"). Echoes them (one line, may be empty). This is the
# declarative contract that makes "a profile's shared resources" uniform; a frontend maps a name
# to its own up/status/stop. Read in a subshell so the profile's other keys don't leak out.
svc_resources_for() {
  local profile="$1" pf
  pf="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/profiles/$profile/profile.conf"
  [ -r "$pf" ] || return 0
  # shellcheck disable=SC1090  # per-profile path is dynamic by design
  ( SHARED_RESOURCES=""; . "$pf" >/dev/null 2>&1; printf '%s\n' "${SHARED_RESOURCES:-}" )
}
