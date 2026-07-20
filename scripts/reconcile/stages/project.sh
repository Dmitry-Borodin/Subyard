#!/usr/bin/env bash
# project.sh — restricted Incus project stage.

[ -n "${SUBYARD_STAGE_PROJECT_SOURCED:-}" ] && return 0
SUBYARD_STAGE_PROJECT_SOURCED=1

stage_project_check() {
  reconcile_incus_reachable && incus project show "$INCUS_PROJECT" >/dev/null 2>&1 || return 1
  [ "$(incus project get "$INCUS_PROJECT" restricted 2>/dev/null || true)" = true ] \
    && [ "$(incus project get "$INCUS_PROJECT" restricted.containers.nesting 2>/dev/null || true)" = allow ] \
    && [ "$(incus project get "$INCUS_PROJECT" restricted.containers.privilege 2>/dev/null || true)" = unprivileged ] \
    && [ "$(incus project get "$INCUS_PROJECT" restricted.devices.disk 2>/dev/null || true)" = allow ] \
    && [ -z "$(incus project get "$INCUS_PROJECT" restricted.devices.disk.paths 2>/dev/null || true)" ] \
    && [ "$(incus project get "$INCUS_PROJECT" restricted.devices.unix-char 2>/dev/null || true)" = allow ] \
    && [ "$(incus project get "$INCUS_PROJECT" restricted.devices.proxy 2>/dev/null || true)" = allow ] \
    || return 1
  local devices
  devices=" $(incus profile device list default --project "$INCUS_PROJECT" 2>/dev/null | tr '\n' ' ') "
  case "$devices" in *' root '*) ;; *) return 1 ;; esac
  case "$devices" in *' eth0 '*) ;; *) return 1 ;; esac
}

stage_project_plan() { printf "Create the Incus project '%s'\n" "$INCUS_PROJECT"; }
stage_project_apply() { "$SCRIPT_DIR/02-create-project.sh" --yes; }
stage_project_verify() { stage_project_check; }
