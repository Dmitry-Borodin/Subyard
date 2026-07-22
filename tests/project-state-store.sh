#!/usr/bin/env bash
# Project state and routing belong to Go; physical shell adapters consume validated snapshots.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for removed in "$ROOT/scripts/state/store.sh" "$ROOT/scripts/state/resolver.sh" \
  "$ROOT/scripts/state/transport.sh" "$ROOT/scripts/project-clone.sh" \
  "$ROOT/scripts/project-remove.sh" "$ROOT/scripts/project-sync.sh" \
	"$ROOT/scripts/project-code.sh" "$ROOT/scripts/project-export.sh" \
	"$ROOT/scripts/lib/project-snapshot.sh" "$ROOT/scripts/state/metadata.sh"; do
  [ ! -e "$removed" ] || fail "retired compatibility shim still exists: ${removed#$ROOT/}"
done

production=(
  scripts/09-yard-extras.sh
)
for relative in "${production[@]}"; do
  if grep -Eq 'state_(engine|get|write|set|remove|exists|ids|validate)|resolve_project|route_sync_target|maybe_reconcile|_project-state' "$ROOT/$relative"; then
    fail "Go-owned project state or routing returned to $relative"
  fi
done

printf 'ok: project state, routing and core actions have one Go owner\n'
