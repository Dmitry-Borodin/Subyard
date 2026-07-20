#!/usr/bin/env bash
# Core command registry is the single source for dispatch, list/help and completion metadata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_NO_AUDIT=1

# shellcheck source=scripts/lib-command-registry.sh
. "$ROOT/scripts/lib-command-registry.sh"
command_registry_validate || fail "command registry validation failed"
command_registry_lookup check || fail 'fixture command lookup failed'
if command_registry_lookup definitely-missing; then fail 'unknown command lookup succeeded'; fi
[ -z "$COMMAND_NAME" ] && [ -z "$COMMAND_HANDLER" ] \
  || fail 'failed command lookup leaked stale registry metadata'

core="$(command_registry_list)"
listed="$($ROOT/bin/yard --list)"
resources="$($ROOT/bin/yard --resources | cut -f1)"
expected="$(printf '%s\n%s\n' "$core" "$resources" | awk 'NF')"
[ "$listed" = "$expected" ] || fail "yard --list drifted from command/resource registries"

manifest="$($ROOT/bin/yard --command-manifest)"
[ "$manifest" = "$(command_registry_manifest)" ] || fail "machine manifest drifted from registry"
help="$($ROOT/bin/yard --help)"

seen=' '
while IFS='|' read -r name aliases handler arg0 remote visibility section completion display summary options verbs; do
  case "$handler" in @*) ;; *) [ -x "$ROOT/scripts/$handler" ] || fail "$name handler is missing: $handler" ;; esac
  [ "$($ROOT/bin/yard --command-completion "$name")" = "$completion" ] \
    || fail "$name completion provider drifted"
  [ "$($ROOT/bin/yard --command-options "$name")" = "$options" ] \
    || fail "$name completion options drifted"
  [ "$($ROOT/bin/yard --command-verbs "$name")" = "$verbs" ] \
    || fail "$name completion verbs drifted"
  case "$seen" in *" $name "*) fail "duplicate command/alias: $name" ;; esac
  seen+="$name "
  if [ -n "$aliases" ]; then
    IFS=, read -r -a alias_list <<<"$aliases"
    for alias in "${alias_list[@]}"; do
      case "$seen" in *" $alias "*) fail "duplicate command/alias: $alias" ;; esac
      seen+="$alias "
      command_registry_lookup "$alias" || fail "alias is not resolved: $alias"
      [ "$COMMAND_NAME" = "$name" ] || fail "alias $alias resolves to $COMMAND_NAME"
      [ "$($ROOT/bin/yard --command-completion "$alias")" = "$completion" ] \
        || fail "$alias completion provider drifted"
    done
  fi
  if [ "$visibility" = public ]; then
    grep -Fq "$display" <<<"$help" || fail "$name missing from generated help"
  fi
done < <(command_registry_rows)

! grep -q "cmds='check\|cmds=( check" "$ROOT/completions/yard.bash" "$ROOT/completions/yard.zsh" \
  || fail "completion contains a duplicate fallback command list"

printf 'ok: command registry drives dispatch metadata, list, help and completions\n'
