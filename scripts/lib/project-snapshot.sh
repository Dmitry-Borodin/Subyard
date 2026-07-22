#!/usr/bin/env bash
# Validated project input supplied by the Go control plane to physical project adapters.
# shellcheck disable=SC2034 # project_snapshot_load intentionally exports caller-visible fields.

[ -n "${SUBYARD_PROJECT_SNAPSHOT_SOURCED:-}" ] && return 0
SUBYARD_PROJECT_SNAPSHOT_SOURCED=1

project_snapshot_load() {
  [ "${SUBYARD_PROJECT_SNAPSHOT:-}" = 1 ] \
    || die "internal: project adapter requires a Go-owned project snapshot"
  case "${SUBYARD_PROJECT_ID:-}" in
    '' | -* | *[!A-Za-z0-9._-]*) die "internal: invalid project snapshot id" ;;
  esac
  case "${SUBYARD_PROJECT_MODE:-}" in sync | git | bind) ;; *) die "internal: invalid project snapshot mode" ;; esac
  [ "${SUBYARD_PROJECT_YARD_PATH:-}" = "/srv/workspaces/$SUBYARD_PROJECT_ID/src" ] \
    || die "internal: invalid project snapshot yard path"
  case "${SUBYARD_PROJECT_DEVICE:-}" in
    ws-* ) ;; *) die "internal: invalid project snapshot device" ;;
  esac

  id="$SUBYARD_PROJECT_ID"
  name="${SUBYARD_PROJECT_NAME:?internal: project snapshot has no name}"
  hostPath="${SUBYARD_PROJECT_HOST_PATH:-}"
  yardPath="$SUBYARD_PROJECT_YARD_PATH"
  mode="$SUBYARD_PROJECT_MODE"
  target="${SUBYARD_PROJECT_TARGET:-}"
  dev="$SUBYARD_PROJECT_DEVICE"
}
