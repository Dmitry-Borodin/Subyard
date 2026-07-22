#!/usr/bin/env bash
# Production shell must be reachable and must not duplicate a native command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'shell ownership: %s\n' "$*" >&2; exit 1; }

production_roots=("$ROOT/scripts" "$ROOT/internal" "$ROOT/config" "$ROOT/bin" "$ROOT/dev" "$ROOT/.github" "$ROOT/Makefile")
while IFS= read -r file; do
  basename="$(basename "$file")"
  referenced=0
  while IFS= read -r source; do
    [ "$source" = "$file" ] || { referenced=1; break; }
  done < <(grep -RFl -- "$basename" "${production_roots[@]}" 2>/dev/null || true)
  [ "$referenced" = 1 ] || fail "orphaned production shell file: ${file#$ROOT/}"
done < <(find "$ROOT/scripts" -type f -name '*.sh' -print | sort)

while IFS='|' read -r name _aliases handler _rest; do
  case "$name" in ''|'#'*) continue ;; esac
  case "$handler" in
    @*) continue ;;
    *.sh)
      [ -f "$ROOT/scripts/$handler" ] || fail "manifest handler is missing: scripts/$handler" ;;
  esac
done < "$ROOT/config/commands.registry"

while IFS='|' read -r name _aliases handler _rest; do
  case "$name:$handler" in ''*':@'*) ;;
    *) continue ;;
  esac
  for candidate in "$ROOT/scripts/$name.sh" "$ROOT/scripts/yard-$name.sh"; do
    [ ! -e "$candidate" ] || fail "native command keeps a replaced shell path: ${candidate#$ROOT/}"
  done
done < "$ROOT/config/commands.registry"

printf 'ok: production shell is reachable and not duplicated by native commands\n'
