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

# svc_resource_up <resource-name> — read-only probe: is a shared resource currently up?
# The status counterpart to svc_resources_for (the declaration). Returns 0 (up) / 1 (down or
# unknown). Deliberately read-only and minimal — launch/bridge/arbitration stay in the per-kind
# frontends (yard-emu.sh / project-staging.sh); this lib only learns each kind's "is it live?"
# signal so `yard status` can summarize without re-implementing or shelling out to those tools.
# Assumes the yard is RUNNING (caller checks); a down yard makes every probe report not-up.
svc_resource_up() {
  case "$1" in
    emulator)
      # L1: the emulator runs in the yard; "up" = its adb port is listening there.
      local port="${ADB_EMULATOR_PORT:-5555}"
      yexec sh -c "command -v ss >/dev/null 2>&1 && ss -Hltn 'sport = :$port' 2>/dev/null | grep -q ." 2>/dev/null
      ;;
    staging-gateway)
      # L2: "up" = any staging-runner box (any zone) has a live gateway pid. The zone's data
      # root /srv/staging/<zone> is bind-mounted into its box at the same path, so the pid file
      # is /srv/staging/<zone>/run/gateway.pid; kill -0 must run in the box's pid namespace.
      yexec sh -c '
        for c in $(docker ps -q --filter "label=subyard.staging=1" 2>/dev/null); do
          z="$(docker inspect -f "{{ index .Config.Labels \"subyard.zone\" }}" "$c" 2>/dev/null)"
          [ -n "$z" ] || continue
          p="/srv/staging/$z/run/gateway.pid"
          docker exec "$c" sh -c "[ -f \"$p\" ] && kill -0 \"\$(cat \"$p\")\" 2>/dev/null" && exit 0
        done
        exit 1' 2>/dev/null
      ;;
    *) return 1 ;;  # unknown resource kind => report not-up rather than erroring
  esac
}
