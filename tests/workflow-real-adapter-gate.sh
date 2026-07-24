#!/usr/bin/env bash
# Host-free contract: CI and Release must use the same real-adapter entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER='tests/real-host/adapter-contracts.sh'
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"

fail() {
  printf 'workflow real-adapter gate: %s\n' "$*" >&2
  exit 1
}

[ -x "$ROOT/$RUNNER" ] || fail "shared runner is missing or not executable: $RUNNER"

for workflow in "$CI_WORKFLOW" "$RELEASE_WORKFLOW"; do
  [ "$(grep -Fc "bash $RUNNER" "$workflow")" -eq 1 ] \
    || fail "$(basename "$workflow") must invoke the shared runner exactly once"
  ! grep -Fq 'scripts/install-key-tools.sh' "$workflow" \
    || fail "$(basename "$workflow") bypasses the prepared-context runner"
done

line_of() {
  grep -nF "$2" "$1" | head -n1 | cut -d: -f1
}

ci_suite_line="$(line_of "$CI_WORKFLOW" 'run: ./tests/run.sh')"
ci_adapter_line="$(line_of "$CI_WORKFLOW" "run: bash $RUNNER")"
[ "$ci_suite_line" -lt "$ci_adapter_line" ] \
  || fail 'CI must run the host-free suite before the real-adapter gate'

release_adapter_line="$(line_of "$RELEASE_WORKFLOW" "run: bash $RUNNER")"
release_build_line="$(line_of "$RELEASE_WORKFLOW" 'name: Build release assets')"
release_publish_line="$(line_of "$RELEASE_WORKFLOW" 'name: Publish GitHub Release')"
[ "$release_adapter_line" -lt "$release_build_line" ] \
  && [ "$release_build_line" -lt "$release_publish_line" ] \
  || fail 'Release must pass the real-adapter gate before building and publishing assets'

printf 'ok: CI and Release share the prepared-context real-adapter gate\n'
