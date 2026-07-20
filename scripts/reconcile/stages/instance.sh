#!/usr/bin/env bash
# instance.sh — L1 yard instance and durable /srv volume stage.

[ -n "${SUBYARD_STAGE_INSTANCE_SOURCED:-}" ] && return 0
SUBYARD_STAGE_INSTANCE_SOURCED=1

stage_instance_check() {
  reconcile_incus_reachable && incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 || return 1
  incus storage volume show "${SRV_POOL:-default}" "${SRV_VOLUME:-yard-srv}" "${PROJ[@]}" >/dev/null 2>&1 \
    || return 1
  local devices source path pool
  devices=" $(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | tr '\n' ' ') "
  case "$devices" in *' srv '*) ;; *) return 1 ;; esac
  source="$(incus config device get "$INSTANCE_NAME" srv source "${PROJ[@]}" 2>/dev/null || true)"
  path="$(incus config device get "$INSTANCE_NAME" srv path "${PROJ[@]}" 2>/dev/null || true)"
  pool="$(incus config device get "$INSTANCE_NAME" srv pool "${PROJ[@]}" 2>/dev/null || true)"
  [ "$source" = "${SRV_VOLUME:-yard-srv}" ] && [ "$path" = /srv ] && [ "$pool" = "${SRV_POOL:-default}" ] \
    || return 1
  if [ "${INSTANCE_TYPE:-container}" = container ]; then
    [ "$(incus config get "$INSTANCE_NAME" security.nesting "${PROJ[@]}" 2>/dev/null || true)" = true ] \
      || return 1
    [ ! -e /dev/kvm ] || case "$devices" in *' kvm '*) ;; *) return 1 ;; esac
  fi
}

stage_instance_plan() { printf 'Create the yard instance (+ /dev/kvm, /srv volume)\n'; }
stage_instance_apply() { "$SCRIPT_DIR/03-create-subyard.sh" --yes; }
stage_instance_verify() { stage_instance_check; }
