#!/usr/bin/env bash
# Focused rollback ordering and migration-registry ownership regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
runtime_root="$TMP/runtime"
calls="$TMP/calls"
engine="$TMP/yard-engine"

cat > "$engine" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
release_root="$(cd "$(dirname "$0")/.." && pwd)"
role="$(basename "$release_root")"
[ "${SUBYARD_REPOSITORY_ROOT:-}" = "$release_root" ] || exit 90
printf '%s %s\n' "$role" "$*" >> "$MIGRATION_CALLS"
case "$role:$*" in
  'old:--version') printf 'yard-engine old\n' ;;
  'old:_migrate check') printf '{"requiredMigrations":["catch-up"]}\n' ;;
  'old:_migrate apply'|'old:_migrate finalize'|'new:_migrate rollback'|'new:_migrate cleanup') ;;
  *) exit 91 ;;
esac
ENGINE
chmod 0700 "$engine"

for release in old new; do
  install -d -m 0700 "$runtime_root/releases/$release/bin"
  install -m 0700 "$engine" "$runtime_root/releases/$release/bin/yard-engine"
done
ln -s releases/new "$runtime_root/current"
ln -s releases/old "$runtime_root/previous"

export MIGRATION_CALLS="$calls"
"$ROOT/scripts/install-runtime-release.sh" --runtime-root "$runtime_root" --rollback >/dev/null

[ "$(readlink "$runtime_root/current")" = releases/old ] \
  && [ "$(readlink "$runtime_root/previous")" = releases/new ] \
  || { printf 'install runtime rollback: runtime links were not swapped\n' >&2; exit 1; }
cat > "$TMP/expected-calls" <<'EOF'
old --version
new _migrate rollback
old _migrate check
old _migrate apply
old _migrate finalize
new _migrate cleanup
old --version
EOF
cmp -s "$TMP/expected-calls" "$calls" \
  || { printf 'install runtime rollback: unexpected migration calls\n' >&2; diff -u "$TMP/expected-calls" "$calls" >&2; exit 1; }

printf 'ok: runtime rollback cleanup uses the replaced runtime registry\n'
