#!/usr/bin/env bash
# Core command registry is the single source for dispatch, list/help and completion metadata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_NO_AUDIT=1

rows="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$ROOT/config/commands.registry")"
core="$(awk -F'|' '$7 == "public" { print $1 }' <<<"$rows")"
listed="$($ROOT/bin/yard --list)"
resources="$($ROOT/bin/yard --resources | cut -f1)"
expected="$(printf '%s\n%s\n' "$core" "$resources" | awk 'NF')"
[ "$listed" = "$expected" ] || fail "yard --list drifted from command/resource registries"

manifest="$($ROOT/bin/yard --command-manifest)"
[ "$manifest" = "$rows" ] || fail "machine manifest drifted from registry"
help="$($ROOT/bin/yard --help)"

seen=' '
while IFS='|' read -r name aliases handler arg0 remote effect visibility section completion display summary options verbs; do
  : "$arg0" "$remote" "$section" "$summary"
  case "$handler" in @*) ;; *) [ -x "$ROOT/scripts/$handler" ] || fail "$name handler is missing: $handler" ;; esac
  [ "$($ROOT/bin/yard --command-completion "$name")" = "$completion" ] \
    || fail "$name completion provider drifted"
  [ "$($ROOT/bin/yard --command-options "$name")" = "$options" ] \
    || fail "$name completion options drifted"
  [ "$($ROOT/bin/yard --command-verbs "$name")" = "$verbs" ] \
    || fail "$name completion verbs drifted"
  [ "$($ROOT/bin/yard --command-effect "$name")" = "$effect" ] \
    || fail "$name command effect drifted"
  case "$effect" in read | mutate) ;; *) fail "$name has invalid command effect: $effect" ;; esac
  case "$seen" in *" $name "*) fail "duplicate command/alias: $name" ;; esac
  seen+="$name "
  if [ -n "$aliases" ]; then
    IFS=, read -r -a alias_list <<<"$aliases"
    for alias in "${alias_list[@]}"; do
      case "$seen" in *" $alias "*) fail "duplicate command/alias: $alias" ;; esac
      seen+="$alias "
      [ "$($ROOT/bin/yard --command-completion "$alias")" = "$completion" ] \
        || fail "$alias completion provider drifted"
    done
  fi
  if [ "$visibility" = public ]; then
    grep -Fq "$display" <<<"$help" || fail "$name missing from generated help"
  fi
done <<<"$rows"

! grep -q "cmds='check\|cmds=( check" "$ROOT/completions/yard.bash" "$ROOT/completions/yard.zsh" \
  || fail "completion contains a duplicate fallback command list"

printf 'ok: command registry drives dispatch metadata, list, help and completions\n'
