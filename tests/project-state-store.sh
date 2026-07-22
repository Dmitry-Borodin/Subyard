#!/usr/bin/env bash
# Project state and routing belong to Go; physical shell adapters consume validated snapshots.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for removed in "$ROOT/scripts/state/store.sh" "$ROOT/scripts/state/resolver.sh" \
  "$ROOT/scripts/state/transport.sh" "$ROOT/scripts/project-clone.sh" \
  "$ROOT/scripts/project-remove.sh" "$ROOT/scripts/project-sync.sh" \
  "$ROOT/scripts/state/metadata.sh"; do
  [ ! -e "$removed" ] || fail "retired compatibility shim still exists: ${removed#$ROOT/}"
done

production=(
  scripts/project-code.sh scripts/project-export.sh scripts/project-env.sh
  scripts/09-yard-extras.sh scripts/10-provision-profile.sh
  scripts/reconcile/stages/provision.sh
)
for relative in "${production[@]}"; do
  if grep -Eq 'state_(engine|get|write|set|remove|exists|ids|validate)|resolve_project|route_sync_target|maybe_reconcile|_project-state' "$ROOT/$relative"; then
    fail "Go-owned project state or routing returned to $relative"
  fi
done

for adapter in \
  scripts/project-code.sh scripts/project-export.sh scripts/project-env.sh; do
  grep -Fq 'project-snapshot.sh' "$ROOT/$adapter" \
    || fail "$adapter does not consume the validated Go project snapshot"
  ! grep -Eq 'subyard_context_load|lib/(runtime|env|registry|config|context|cache)\.sh|state/transport\.sh' \
    "$ROOT/$adapter" || fail "$adapter reloads Go-owned control-plane state"
  ! grep -Eq '^[[:space:]]*(announce|proceed_or_die)\b' "$ROOT/$adapter" \
    || fail "$adapter duplicates the Go-owned operation plan"
done

! grep -Eq '^[[:space:]]*(list|shell|exec|destroy)\)' "$ROOT/scripts/project-env.sh" \
  || fail 'project-env adapter exposes a command absent from the registry'

printf 'ok: project state and routing have one Go owner; shell adapters consume snapshots only\n'
