#!/usr/bin/env bash
# incus.sh — Incus presence, version, storage and bridge stage.

[ -n "${SUBYARD_STAGE_INCUS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_INCUS_SOURCED=1

stage_incus_present() { command -v incus >/dev/null 2>&1; }
stage_incus_in_admin_db() { id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; }
stage_incus_recent() {
  local version
  version="$(incus --version 2>/dev/null || printf '?')"
  [ "$version" != '?' ] && command -v dpkg >/dev/null 2>&1 \
    && dpkg --compare-versions "$version" ge "$MIN_INCUS_VER"
}
stage_incus_too_old() { stage_incus_present && ! stage_incus_recent; }

# apt's candidate Incus is too old (or unknown), so a fresh distro install misses the floor.
stage_incus_distro_too_old() {
  command -v apt-get >/dev/null 2>&1 || return 1
  command -v apt-cache >/dev/null 2>&1 || return 0
  local candidate
  candidate="$(apt-cache policy incus 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  if [ -n "$candidate" ] && [ "$candidate" != '(none)' ] && command -v dpkg >/dev/null 2>&1 \
    && dpkg --compare-versions "$candidate" ge "$MIN_INCUS_VER"; then
    return 1
  fi
  return 0
}

stage_incus_initialized() {
  reconcile_incus_reachable \
    && incus storage show "$STORAGE_POOL" >/dev/null 2>&1 \
    && incus network show "$INCUS_BRIDGE" >/dev/null 2>&1
}

stage_incus_check() { stage_incus_initialized && stage_incus_recent; }
stage_incus_plan() {
  if ! stage_incus_initialized; then
    printf "Install Incus, add you to 'incus-admin', and initialize storage (needs root)\n"
  elif stage_incus_too_old; then
    printf 'Upgrade Incus to >= %s for nested Docker (needs root)\n' "$MIN_INCUS_VER"
  else
    printf 'Incus installed, initialized, and >= %s\n' "$MIN_INCUS_VER"
  fi
}
stage_incus_apply() { incus_install_or_upgrade; }
stage_incus_verify() { stage_incus_check; }
