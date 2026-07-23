#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT=subyard-p0-real-incus
MARKER=agent-e2e-p0
CONTAINER_IMAGE="${P0_REAL_INCUS_CONTAINER_IMAGE:-images:debian/13/cloud}"
VM_IMAGE="${P0_REAL_INCUS_VM_IMAGE:-images:debian/13/cloud}"
CONTAINER_CACHE_ALIAS="${P0_REAL_INCUS_CONTAINER_CACHE_ALIAS:-subyard-e2e-debian-13-cloud-container}"
VM_CACHE_ALIAS="${P0_REAL_INCUS_VM_CACHE_ALIAS:-subyard-e2e-debian-13-cloud-vm}"
TMP=''

die() { printf 'p0-real-incus: %s\n' "$*" >&2; exit 2; }
# Incus create/init/launch may consume YAML from stdin. The P0 lane is reached through SSH, so an
# inherited non-TTY stream can stay open forever after the operation itself succeeds.
real_incus() { timeout --foreground "${P0_REAL_INCUS_COMMAND_TIMEOUT:-900}" incus "$@" </dev/null; }
real_incus_quiet() { real_incus "$@" >/dev/null; }
project_exists() { real_incus project show "$PROJECT" >/dev/null 2>&1; }

run_with_progress() {
  local label="$1" interval="${E2E_PROGRESS_INTERVAL:-10}" ticker rc started=$SECONDS
  shift
  printf '  [ .. ] %s\n' "$label"
  (
    while sleep "$interval"; do
      printf '  [ .. ] %s (still working, %ss elapsed)\n' "$label" "$((SECONDS - started))"
    done
  ) &
  ticker=$!
  if "$@"; then rc=0; else rc=$?; fi
  kill "$ticker" 2>/dev/null || true
  wait "$ticker" 2>/dev/null || true
  return "$rc"
}

cleanup() {
  local name
  if project_exists; then
    [ "$(real_incus project get "$PROJECT" user.subyard.p0 2>/dev/null)" = "$MARKER" ] \
      || die "refusing to clean unmarked project $PROJECT"
    for name in p0-container p0-vm; do
      if real_incus config show "$name" --project "$PROJECT" >/dev/null 2>&1; then
        [ "$(real_incus config get "$name" user.subyard.p0 --project "$PROJECT")" = "$MARKER" ] \
          || die "refusing to clean unmarked instance $name"
        real_incus delete "$name" --project "$PROJECT" --force >/dev/null
      fi
    done
    [ -z "$(real_incus list --project "$PROJECT" -f csv -c n)" ] \
      || die "unexpected instance remains in $PROJECT"
    real_incus project delete "$PROJECT" >/dev/null
  fi
  if [ -n "$TMP" ] && [[ "$TMP" = /tmp/subyard-p0-incus.* ]] && [ -d "$TMP" ]; then
    find "$TMP" -depth -delete
  fi
}
trap cleanup EXIT

[ -n "${SUBYARD_E2E_VM:-}" ] || die 'run through dev/agent-e2e.sh'
for command in go incus sudo; do command -v "$command" >/dev/null || die "$command is required"; done
sudo -n true || die 'passwordless sudo is required in a disposable test VM'
[ -S /var/lib/incus/unix.socket ] || die 'Incus socket is unavailable'
project_exists && cleanup
if cache_info="$(real_incus image info "$CONTAINER_CACHE_ALIAS" --project default 2>/dev/null)"; then
  printf '%s\n' "$cache_info" | grep -Fqx 'Type: container' \
    || die "provisioned image alias $CONTAINER_CACHE_ALIAS is not a container image"
  CONTAINER_IMAGE="$CONTAINER_CACHE_ALIAS"
  printf '  [ ok ] using provisioned real-Incus container image %s\n' "$CONTAINER_CACHE_ALIAS"
fi
if cache_info="$(real_incus image info "$VM_CACHE_ALIAS" --project default 2>/dev/null)"; then
  printf '%s\n' "$cache_info" | grep -Fqx 'Type: virtual-machine' \
    || die "provisioned image alias $VM_CACHE_ALIAS is not a VM image"
  VM_IMAGE="$VM_CACHE_ALIAS"
  printf '  [ ok ] using provisioned real-Incus VM image %s\n' "$VM_CACHE_ALIAS"
fi

real_incus project create "$PROJECT" \
  -c features.images=false -c features.profiles=false -c features.storage.volumes=false >/dev/null
real_incus project set "$PROJECT" user.subyard.p0="$MARKER"
run_with_progress "launching real Incus container (first use may download an image)" \
  real_incus_quiet launch "$CONTAINER_IMAGE" p0-container --project "$PROJECT" --storage default \
  -c user.subyard.p0="$MARKER"
if ! real_incus image info "$CONTAINER_CACHE_ALIAS" --project default >/dev/null 2>&1; then
  container_fingerprint="$(real_incus config get p0-container volatile.base_image --project "$PROJECT")"
  [[ "$container_fingerprint" =~ ^[0-9a-f]{64}$ ]] \
    || die 'real-Incus container base image fingerprint is invalid'
  real_incus image alias create "$CONTAINER_CACHE_ALIAS" "$container_fingerprint" --project default
  printf '  [ ok ] retained test-owned container image alias %s\n' "$CONTAINER_CACHE_ALIAS"
fi
run_with_progress "launching real Incus VM (a clean allocation may download an image)" \
  real_incus_quiet launch "$VM_IMAGE" p0-vm --vm --project "$PROJECT" \
  --storage default \
  -c limits.cpu=1 -c limits.memory=1GiB -c user.subyard.p0="$MARKER" \
  -d root,size=5GiB

for name in p0-container p0-vm; do
  printf '  [ .. ] waiting for %s\n' "$name"
  for _ in $(seq 1 120); do
    real_incus exec "$name" --project "$PROJECT" -- true >/dev/null 2>&1 && break
    sleep 2
  done
  real_incus exec "$name" --project "$PROJECT" -- true >/dev/null 2>&1 \
    || die "$name did not become ready"
done

TMP="$(mktemp -d /tmp/subyard-p0-incus.XXXXXX)"
go test -c -tags realincus -o "$TMP/incusclient-real.test" ./internal/adapters/incusclient
sudo -n env \
  SUBYARD_REAL_INCUS_SOCKET=/var/lib/incus/unix.socket \
  SUBYARD_REAL_INCUS_CONTAINER_PROJECT="$PROJECT" \
  SUBYARD_REAL_INCUS_CONTAINER_INSTANCE=p0-container \
  SUBYARD_REAL_INCUS_VM_PROJECT="$PROJECT" \
  SUBYARD_REAL_INCUS_VM_INSTANCE=p0-vm \
  SUBYARD_REAL_INCUS_TEST_BINARY="$TMP/incusclient-real.test" \
  bash "$ROOT/tests/real-host/incus-contract.sh"
cleanup
trap - EXIT
project_exists && die "$PROJECT remains after cleanup"
printf 'ok: real Incus resources passed and were removed\n'
