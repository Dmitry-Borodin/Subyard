#!/usr/bin/env bash
# Host-free top-level CLI/help/completion contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_NO_AUDIT=1

commands="$($ROOT/bin/yard --list)"
grep -qx security <<<"$commands" || fail "security command missing"
"$ROOT/bin/yard" -y --list >/dev/null || fail "leading global --yes is not accepted"
"$ROOT/bin/yard" --help >/dev/null
"$ROOT/bin/yard" --resources >/dev/null
"$ROOT/bin/yard" --version >/dev/null

for cmd in $commands; do "$ROOT/bin/yard" "$cmd" --help >/dev/null; done

profiles="$(for f in "$ROOT"/config/profiles/*/profile.conf; do basename "$(dirname "$f")"; done | sort)"
bash_profiles="$(TEST_ROOT="$ROOT" bash -c '. "$TEST_ROOT/completions/yard.bash"; _yard_repo(){ printf "%s\\n" "$TEST_ROOT"; }; _yard_profiles yard' | sort)"
[ "$bash_profiles" = "$profiles" ] || fail "bash completion profiles drifted"

printf 'ok: CLI help, globals and profile completion contract\n'
