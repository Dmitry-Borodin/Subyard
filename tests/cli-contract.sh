#!/usr/bin/env bash
# Host-free top-level CLI/help/completion contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_NO_AUDIT=1
CLI_TMP="$(mktemp -d)"
trap 'rm -rf "$CLI_TMP"' EXIT

commands="$($ROOT/bin/yard --list)"
grep -qx security <<<"$commands" || fail "security command missing"
"$ROOT/bin/yard" -y --list >/dev/null || fail "leading global --yes is not accepted"
"$ROOT/bin/yard" --help >/dev/null
"$ROOT/bin/yard" --resources >/dev/null
"$ROOT/bin/yard" --version >/dev/null
if "$ROOT/bin/yard" rpc >/dev/null 2>&1; then fail "rpc accepted a non-stdio invocation"; fi

set +e
"$ROOT/bin/yard" definitely-not-a-command >"$CLI_TMP/unknown" 2>&1
unknown_rc=$?
set -e
[ "$unknown_rc" -eq 2 ] || fail "unknown command returned $unknown_rc instead of 2"

for cmd in $commands; do "$ROOT/bin/yard" "$cmd" --help >/dev/null; done

profiles="$(for f in "$ROOT"/config/profiles/*/profile.conf; do basename "$(dirname "$f")"; done | sort)"
bash_profiles="$(TEST_ROOT="$ROOT" bash -c '. "$TEST_ROOT/completions/yard.bash"; _yard_repo(){ printf "%s\\n" "$TEST_ROOT"; }; _yard_profiles yard' | sort)"
[ "$bash_profiles" = "$profiles" ] || fail "bash completion profiles drifted"

# Bash consumes option/verb tokens from the command manifest, including options that previously
# drifted from Zsh (`init --reset`, profile values, and the global resource listing).
completion_words="$({
  # shellcheck source=completions/yard.bash
  . "$ROOT/completions/yard.bash"
  COMP_WORDS=("$ROOT/bin/yard" init --r); COMP_CWORD=2; _yard; printf '%s\n' "${COMPREPLY[@]}"
  COMP_WORDS=("$ROOT/bin/yard" provision ope); COMP_CWORD=2; _yard; printf '%s\n' "${COMPREPLY[@]}"
  COMP_WORDS=("$ROOT/bin/yard" --res); COMP_CWORD=1; _yard; printf '%s\n' "${COMPREPLY[@]}"
} | sort -u)"
grep -qx -- '--reset' <<<"$completion_words" || fail 'Bash completion omitted manifest init options'
grep -qx -- 'openclaw' <<<"$completion_words" || fail 'Bash completion omitted profile values'
grep -qx -- '--resources' <<<"$completion_words" || fail 'Bash completion omitted global resources option'
grep -Fq -- '--command-options' "$ROOT/completions/yard.zsh" \
  && grep -Fq -- '--command-verbs' "$ROOT/completions/yard.zsh" \
  || fail 'Zsh completion does not consume manifest options and verbs'

printf 'ok: CLI help, globals and profile completion contract\n'
