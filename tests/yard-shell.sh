#!/usr/bin/env bash
# Regression: `yard shell` is dev-first, supports --root, and resolves project names.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SUBYARD_HOME="$TMP/subyard"
export SUBYARD_CONFIG_HOME="$TMP/config"
export SUBYARD_STATE_DIR="$TMP/config/projects"
export SUBYARD_NO_AUDIT=1
export INCUS_LOG="$TMP/incus.log"
mkdir -p "$SUBYARD_STATE_DIR" "$TMP/bin"
chmod 0700 "$SUBYARD_STATE_DIR"
cat >"$TMP/bin/incus" <<'SH'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  list) printf 'RUNNING\n' ;;
  exec) printf '%s\n' "$*" >"$INCUS_LOG" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/incus"
export PATH="$TMP/bin:$PATH"
cat >"$SUBYARD_STATE_DIR/subyard-id.json" <<'JSON'
{"schema":1,"projectId":"subyard-id","name":"Subyard","hostPath":"/host/Subyard","yardPath":"/srv/workspaces/subyard-id/src","mode":"sync","sshHost":"yard","target":"yard"}
JSON
chmod 0600 "$SUBYARD_STATE_DIR/subyard-id.json"

"$ROOT/bin/yard" shell -- true
grep -Fq -- '--user 1000 --group 1000 --env HOME=/home/dev --cwd /home/dev -- true' "$INCUS_LOG"

"$ROOT/bin/yard" shell --root -- id -u
grep -Fq -- '--user 0 --group 0 --env HOME=/root --cwd /home/dev -- id -u' "$INCUS_LOG"

"$ROOT/bin/yard" shell Subyard -- pwd
grep -Fq -- '--user 1000 --group 1000 --env HOME=/home/dev --cwd /srv/workspaces/subyard-id/src -- pwd' "$INCUS_LOG"

if "$ROOT/bin/yard" ssh >/dev/null 2>&1; then
  printf 'yard ssh unexpectedly remains available\n' >&2
  exit 1
fi

printf 'ok: yard shell defaults to dev, supports --root, and opens projects\n'
