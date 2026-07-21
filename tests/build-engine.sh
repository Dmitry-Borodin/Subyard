#!/usr/bin/env bash
# Source engine freshness follows production inputs, not test-only Go files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fixture="$TMP/repository"
no_go_path="$TMP/no-go-bin"

install -d "$fixture/scripts" "$fixture/cmd/yard" "$fixture/internal/sample" "$fixture/.build" "$no_go_path"
for command in bash dirname find grep readlink uname; do
  ln -s "$(command -v "$command")" "$no_go_path/$command"
done
install -m 0755 "$ROOT/scripts/build-engine.sh" "$fixture/scripts/build-engine.sh"
printf 'module example.invalid/fixture\n\ngo 1.26.0\n' > "$fixture/go.mod"
: > "$fixture/go.sum"
printf 'package main\nfunc main() {}\n' > "$fixture/cmd/yard/main.go"
printf 'package sample\n' > "$fixture/internal/sample/sample_test.go"
install -m 0755 /dev/null "$fixture/.build/yard"

touch -d '2035-01-01T00:00:00Z' "$fixture/internal/sample/sample_test.go"
PATH="$no_go_path" /bin/bash "$fixture/scripts/build-engine.sh"

touch -d '2036-01-01T00:00:00Z' "$fixture/cmd/yard/main.go"
if PATH="$no_go_path" /bin/bash "$fixture/scripts/build-engine.sh" >"$TMP/stdout" 2>"$TMP/stderr"; then
  printf 'build-engine: production source change did not require a rebuild\n' >&2
  exit 1
fi
grep -Fq 'Go is required' "$TMP/stderr" \
  || { printf 'build-engine: missing-Go diagnostic regressed\n' >&2; exit 1; }

[ -x "$ROOT/bin/yard-engine" ] \
  || { printf 'build-engine: checked-in bootstrap engine is missing\n' >&2; exit 1; }
[ "$(PATH="$no_go_path" "$ROOT/bin/yard" --version)" = 'yard 0.1.0-dev' ] \
  || { printf 'build-engine: checked-in bootstrap did not run without Go\n' >&2; exit 1; }

printf 'ok: engine freshness is source-aware and the checked-in bootstrap runs without Go\n'
