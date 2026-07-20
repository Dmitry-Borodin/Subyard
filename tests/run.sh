#!/usr/bin/env bash
# One host-free entrypoint used locally and in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t syntax_files < <(printf '%s\n' \
  "$ROOT/bin/yard" \
  "$ROOT"/scripts/*.sh \
  "$ROOT"/config/profiles/*/*.sh \
  "$ROOT"/config/agents/*/*.sh \
  "$ROOT"/tests/helpers/*.sh \
  "$ROOT"/tests/*.sh)
for file in "${syntax_files[@]}"; do bash -n "$file"; done

for test_file in "$ROOT"/tests/*.sh; do
  [ "$(basename "$test_file")" = run.sh ] && continue
  printf 'RUN %s\n' "${test_file#"$ROOT/"}"
  bash "$test_file"
done
