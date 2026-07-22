#!/usr/bin/env bash
# Project input supplied by the Go control plane to physical adapters.
# shellcheck disable=SC2034 # project_snapshot_load intentionally exports caller-visible fields.

[ -n "${SUBYARD_PROJECT_SNAPSHOT_SOURCED:-}" ] && return 0
SUBYARD_PROJECT_SNAPSHOT_SOURCED=1

project_snapshot_load() {
  [ "${SUBYARD_PROJECT_SNAPSHOT:-}" = 1 ] \
    || die "internal: project adapter requires a Go-owned project snapshot"
  id="${SUBYARD_PROJECT_ID:?internal: project snapshot has no id}"
  name="${SUBYARD_PROJECT_NAME:?internal: project snapshot has no name}"
  hostPath="${SUBYARD_PROJECT_HOST_PATH:-}"
  yardPath="${SUBYARD_PROJECT_YARD_PATH:?internal: project snapshot has no yard path}"
  mode="${SUBYARD_PROJECT_MODE:?internal: project snapshot has no mode}"
  target="${SUBYARD_PROJECT_TARGET:-}"
  dev="${SUBYARD_PROJECT_DEVICE:?internal: project snapshot has no device}"
}
