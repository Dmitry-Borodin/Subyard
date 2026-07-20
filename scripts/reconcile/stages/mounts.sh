#!/usr/bin/env bash
# mounts.sh — bidirectional reconciliation of core host-* mounts.

[ -n "${SUBYARD_STAGE_MOUNTS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_MOUNTS_SOURCED=1

stage_mounts_check() {
  reconcile_incus_reachable || return 1
  local attached desired='' name path access _mode source actual_readonly want_readonly device
  attached=" $(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | tr '\n' ' ') "
  while IFS=: read -r name path access _mode; do
    [ -n "$name" ] || continue
    desired+=" $name"
    case "$attached" in *" $name "*) ;; *) return 1 ;; esac
    source="$(incus config device get "$INSTANCE_NAME" "$name" source "${PROJ[@]}" 2>/dev/null || true)"
    [ "$source" = "$HOST_BASE/$name" ] || return 1
    [ "$(incus config device get "$INSTANCE_NAME" "$name" path "${PROJ[@]}" 2>/dev/null || true)" = "$path" ] \
      || return 1
    actual_readonly="$(incus config device get "$INSTANCE_NAME" "$name" readonly "${PROJ[@]}" 2>/dev/null || true)"
    want_readonly=false
    [ "$access" = ro ] && want_readonly=true
    case "$actual_readonly" in '' | false) actual_readonly=false ;; esac
    [ "$actual_readonly" = "$want_readonly" ] || return 1
  done < <(printf '%s\n' "${HOST_MOUNTS:-}" | sed 's/[[:space:]]//g')
  while IFS= read -r device; do
    case "$device" in host-*) ;; *) continue ;; esac
    case " $desired " in *" $device "*) ;; *) return 1 ;; esac
  done < <(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null)
}

stage_mounts_plan() { printf 'Create host dirs under %s and mount them (needs root)\n' "$HOST_BASE"; }
stage_mounts_apply() { "$SCRIPT_DIR/05-mount-host-paths.sh" --yes; }
stage_mounts_verify() { stage_mounts_check; }
