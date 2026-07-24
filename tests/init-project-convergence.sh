#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export MOCK_INCUS_LOG="$TMP/incus.log"
export MOCK_PROJECT="$TMP/project"
mkdir -p "$HOME" "$TMP/bin"

cat > "$TMP/bin/incus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${INCUS_PROJECT:-}" "$*" >>"$MOCK_INCUS_LOG"
case "${1:-} ${2:-}" in
  'info ') exit 0 ;;
  'project show') [ -e "$MOCK_PROJECT" ] ;;
  'project create')
    [ "${INCUS_PROJECT:-}" = default ]
    if IFS= read -r unexpected; then
      printf 'project create consumed stdin: %s\n' "$unexpected" >&2
      exit 91
    fi
    touch "$MOCK_PROJECT"
    ;;
  'project set' | 'project unset') ;;
  'project get') ;;
  'profile device')
    [ "${3:-}" = list ] || [ "${3:-}" = add ]
    ;;
  *) printf 'unexpected incus call: %s\n' "$*" >&2; exit 90 ;;
esac
MOCK
chmod +x "$TMP/bin/incus"

printf 'must-not-reach-incus\n' | "$ROOT/scripts/02-create-project.sh" --yes >/dev/null
"$ROOT/scripts/02-create-project.sh" --yes >/dev/null

[ "$(grep -Fc 'default|project create subyard' "$MOCK_INCUS_LOG")" = 1 ] \
  || fail 'project creation did not use the default Incus context exactly once'
printf 'ok: project creation closes stdin and is independent of its absent context\n'
