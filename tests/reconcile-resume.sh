#!/usr/bin/env bash
# Reconciliation resumes after partial failure, skips converged work and repairs later drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home" SUBYARD_NO_AUDIT=1
mkdir -p "$HOME"
# shellcheck source=scripts/init.sh
. "$ROOT/scripts/init.sh"

stage_a_check() { [ -e "$TMP/a.done" ]; }
stage_a_plan() { printf 'fixture A\n'; }
stage_a_apply() { printf 'a\n' >> "$TMP/apply.log"; : > "$TMP/a.done"; }
stage_a_verify() { stage_a_check; }

stage_b_check() { [ -e "$TMP/b.done" ]; }
stage_b_plan() { printf 'fixture B\n'; }
stage_b_apply() {
  printf 'b\n' >> "$TMP/apply.log"
  if [ ! -e "$TMP/b.failed-once" ]; then : > "$TMP/b.failed-once"; return 23; fi
  : > "$TMP/b.done"
}
stage_b_verify() { stage_b_check; }
RECONCILE_STAGES=('a|stage_a' 'b|stage_b')

if (reconcile_run_stages) >"$TMP/first.out" 2>&1; then
  fail 'partial stage failure was reported as success'
fi
stage_a_check || fail 'completed stage A was lost after stage B failed'
! stage_b_check || fail 'failed stage B was marked converged'

reconcile_run_stages >/dev/null
[ "$(grep -c '^a$' "$TMP/apply.log")" -eq 1 ] || fail 'resume reapplied converged stage A'
[ "$(grep -c '^b$' "$TMP/apply.log")" -eq 2 ] || fail 'resume did not retry failed stage B exactly once'

rm "$TMP/a.done"
reconcile_run_stages >/dev/null
[ "$(grep -c '^a$' "$TMP/apply.log")" -eq 2 ] || fail 'drifted stage A was not repaired'
[ "$(grep -c '^b$' "$TMP/apply.log")" -eq 2 ] || fail 'drift repair disturbed converged stage B'

printf 'ok: reconciler resumes, skips no-op stages and repairs drift\n'
