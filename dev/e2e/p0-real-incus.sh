#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT=subyard-p0-real-incus
MARKER=agent-e2e-p0
TMP=''

die() { printf 'p0-real-incus: %s\n' "$*" >&2; exit 2; }
project_exists() { incus project show "$PROJECT" >/dev/null 2>&1; }

cleanup() {
  local name
  if project_exists; then
    [ "$(incus project get "$PROJECT" user.subyard.p0 2>/dev/null)" = "$MARKER" ] \
      || die "refusing to clean unmarked project $PROJECT"
    for name in p0-container p0-vm; do
      if incus config show "$name" --project "$PROJECT" >/dev/null 2>&1; then
        [ "$(incus config get "$name" user.subyard.p0 --project "$PROJECT")" = "$MARKER" ] \
          || die "refusing to clean unmarked instance $name"
        incus delete "$name" --project "$PROJECT" --force >/dev/null
      fi
    done
    [ -z "$(incus list --project "$PROJECT" -f csv -c n)" ] \
      || die "unexpected instance remains in $PROJECT"
    incus project delete "$PROJECT" >/dev/null
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

incus project create "$PROJECT" \
  -c features.images=false -c features.profiles=false -c features.storage.volumes=false >/dev/null
incus project set "$PROJECT" user.subyard.p0="$MARKER"
incus launch images:debian/13/cloud p0-container --project "$PROJECT" --storage default \
	-c user.subyard.p0="$MARKER" >/dev/null
incus launch images:debian/13/cloud p0-vm --vm --project "$PROJECT" \
	--storage default \
	-c limits.cpu=1 -c limits.memory=1GiB -c user.subyard.p0="$MARKER" \
	-d root,size=5GiB >/dev/null

for name in p0-container p0-vm; do
  printf '  [ .. ] waiting for %s\n' "$name"
  for _ in $(seq 1 120); do
    incus exec "$name" --project "$PROJECT" -- true >/dev/null 2>&1 && break
    sleep 2
  done
  incus exec "$name" --project "$PROJECT" -- true >/dev/null 2>&1 \
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
