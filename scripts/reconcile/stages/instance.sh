#!/usr/bin/env bash
# instance.sh — L1 yard instance and durable /srv volume stage.

[ -n "${SUBYARD_STAGE_INSTANCE_SOURCED:-}" ] && return 0
SUBYARD_STAGE_INSTANCE_SOURCED=1

stage_instance_char_matches() { # <device> <source>
  [ "$(incus config device get "$INSTANCE_NAME" "$1" type "${PROJ[@]}" 2>/dev/null || true)" = unix-char ] \
    && [ "$(incus config device get "$INSTANCE_NAME" "$1" source "${PROJ[@]}" 2>/dev/null || true)" = "$2" ] \
    && [ "$(incus config device get "$INSTANCE_NAME" "$1" path "${PROJ[@]}" 2>/dev/null || true)" = "$2" ]
}

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
    if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
      [ "$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf "${PROJ[@]}" 2>/dev/null || true)" = true ] \
        && [ "$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf.devices "${PROJ[@]}" 2>/dev/null || true)" = true ] \
        || return 1
      case "$devices" in *' kvm '*) ;; *) return 1 ;; esac
      case "$devices" in *' e2e-vsock '*) ;; *) return 1 ;; esac
      case "$devices" in *' e2e-vhost-vsock '*) ;; *) return 1 ;; esac
      case "$devices" in *' e2e-tun '*) ;; *) return 1 ;; esac
      stage_instance_char_matches kvm /dev/kvm \
        && stage_instance_char_matches e2e-vsock /dev/vsock \
        && stage_instance_char_matches e2e-vhost-vsock /dev/vhost-vsock \
        && stage_instance_char_matches e2e-tun /dev/net/tun \
        || return 1
    else
      [ -z "$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf "${PROJ[@]}" 2>/dev/null || true)" ] \
        && [ -z "$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf.devices "${PROJ[@]}" 2>/dev/null || true)" ] \
        || return 1
      case "$devices" in *' e2e-vsock '* | *' e2e-vhost-vsock '* | *' e2e-tun '*) return 1 ;; esac
    fi
    if reconcile_host_has_kvm; then
      case "$devices" in *' kvm '*) ;; *) return 1 ;; esac
    fi
  fi
}

stage_instance_plan() {
  if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
    printf 'Create the yard instance (+ trusted nested-VM KVM/vsock/BPF boundary, /srv volume)\n'
  else
    printf 'Create the yard instance (+ /dev/kvm, /srv volume)\n'
  fi
}
stage_instance_apply() { "$SCRIPT_DIR/03-create-subyard.sh" --yes; }
stage_instance_verify() { stage_instance_check; }
