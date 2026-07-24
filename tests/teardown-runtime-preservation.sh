#!/usr/bin/env bash
# Last-yard teardown removes mutable yard data without uninstalling the verified CLI runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SUBYARD_OPERATOR_HOME="$TMP/operator"
# shellcheck source=scripts/lib/engine-context.sh
. "$ROOT/scripts/lib/engine-context.sh"
# shellcheck source=scripts/lib/host.sh
. "$ROOT/scripts/lib/host.sh"

incus() {
  [ "$1 $2 $3 $4" = "project get fixture features.images" ] || return 1
  printf '%s\n' "$INCUS_FEATURES_IMAGES"
}
INCUS_FEATURES_IMAGES=false
! incus_project_has_isolated_images fixture \
  || fail 'shared default-project images were treated as yard-owned'
INCUS_FEATURES_IMAGES=true
incus_project_has_isolated_images fixture \
  || fail 'isolated project images were not treated as yard-owned'

data_home="$TMP/default-home"
runtime_root="$data_home/runtime"
install -d "$runtime_root/current/bin" "$data_home/incus/storage" "$data_home/ssh" "$data_home/logs"
printf '#!/bin/sh\nexit 0\n' > "$runtime_root/current/bin/yard"
chmod +x "$runtime_root/current/bin/yard"
printf 'mutable\n' > "$data_home/logs/yard.log"

subyard_home_remove_preserving_runtime "$data_home" "$runtime_root" \
  || fail 'default runtime cleanup failed'
[ -x "$runtime_root/current/bin/yard" ] || fail 'default installed runtime was removed'
[ "$SUBYARD_PRESERVED_RUNTIME" = "$runtime_root" ] || fail 'default preserved runtime was not reported'
[ ! -e "$data_home/incus" ] && [ ! -e "$data_home/ssh" ] && [ ! -e "$data_home/logs" ] \
  || fail 'mutable default yard data remained'

custom_home="$TMP/custom-home"
custom_runtime="$custom_home/releases/runtime"
install -d "$custom_runtime/current/bin" "$custom_home/projects" "$custom_home/space"
printf '#!/bin/sh\nexit 0\n' > "$custom_runtime/current/bin/yard"
chmod +x "$custom_runtime/current/bin/yard"

subyard_home_remove_preserving_runtime "$custom_home" "$custom_runtime" \
  || fail 'custom nested runtime cleanup failed'
[ -x "$custom_runtime/current/bin/yard" ] || fail 'custom nested runtime was removed'
[ ! -e "$custom_home/projects" ] && [ ! -e "$custom_home/space" ] \
  || fail 'mutable custom yard data remained'

external_home="$TMP/external-home"
external_runtime="$TMP/external-runtime"
install -d "$external_home/data" "$external_runtime/current/bin"
printf '#!/bin/sh\nexit 0\n' > "$external_runtime/current/bin/yard"
chmod +x "$external_runtime/current/bin/yard"

subyard_home_remove_preserving_runtime "$external_home" "$external_runtime" \
  || fail 'external runtime cleanup failed'
[ ! -e "$external_home" ] || fail 'yard data home remained for an external runtime'
[ -x "$external_runtime/current/bin/yard" ] || fail 'external runtime was removed'

incomplete_home="$TMP/incomplete-home"
install -d "$incomplete_home/runtime/current/bin" "$incomplete_home/data"
subyard_home_remove_preserving_runtime "$incomplete_home" "$incomplete_home/runtime" \
  || fail 'incomplete runtime cleanup failed'
[ ! -e "$incomplete_home" ] || fail 'incomplete runtime incorrectly blocked cleanup'

if subyard_home_remove_preserving_runtime / /runtime; then
  fail 'broad data root was accepted'
fi

printf 'ok: last-yard teardown preserves only an installed runtime\n'
