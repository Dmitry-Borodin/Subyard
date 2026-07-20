#!/usr/bin/env bash
# One host-free entrypoint used locally and in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t syntax_files < <(
  printf '%s\n' "$ROOT/bin/yard"
  find "$ROOT/scripts" "$ROOT/config/profiles" "$ROOT/config/agents" "$ROOT/tests" \
    -type f -name '*.sh' -print | sort
)
for file in "${syntax_files[@]}"; do bash -n "$file"; done

mapfile -t actual_tests < <(find "$ROOT/tests" -maxdepth 1 -type f -name '*.sh' ! -name run.sh -printf '%f\n' | sort)
mapfile -t declared_tests < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$ROOT"/tests/suites/*.list | sort)
[ "${#actual_tests[@]}" -eq "${#declared_tests[@]}" ] \
  || { printf 'FAIL: test suite manifests omit or duplicate a top-level test\n' >&2; exit 1; }
for i in "${!actual_tests[@]}"; do
  [ "${actual_tests[$i]}" = "${declared_tests[$i]}" ] \
    || { printf 'FAIL: test suite manifests drifted near %s / %s\n' \
      "${actual_tests[$i]}" "${declared_tests[$i]}" >&2; exit 1; }
done

for suite in unit contract integration; do
  printf 'SUITE %s\n' "$suite"
  while IFS= read -r test_name; do
    case "$test_name" in '' | '# '*) continue ;; esac
    printf 'RUN tests/%s\n' "$test_name"
    bash "$ROOT/tests/$test_name"
  done < "$ROOT/tests/suites/$suite.list"
done
