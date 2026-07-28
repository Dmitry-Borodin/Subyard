#!/usr/bin/env bash
# Real-network smoke for both Zabbly repository callers on one leased disposable VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY=/etc/apt/keyrings/zabbly.asc
SOURCE=/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources
TMP=''
KEY_EXISTED=0
SOURCE_EXISTED=0

die() { printf 'zabbly-download-smoke: %s\n' "$*" >&2; exit 2; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$TMP" ] && [[ "$TMP" = /tmp/subyard-zabbly-smoke.* ]] && [ -d "$TMP" ]; then
    if [ "$KEY_EXISTED" = 1 ]; then
      rm -f -- "$KEY"
      cp -a -- "$TMP/zabbly.asc" "$KEY"
    else
      rm -f -- "$KEY"
    fi
    if [ "$SOURCE_EXISTED" = 1 ]; then
      rm -f -- "$SOURCE"
      cp -a -- "$TMP/zabbly.sources" "$SOURCE"
    else
      rm -f -- "$SOURCE"
    fi
    find "$TMP" -depth -delete
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

[ -n "${SUBYARD_E2E_VM:-}" ] || die 'run through dev/agent-e2e.sh'
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -n env SUBYARD_E2E_VM="$SUBYARD_E2E_VM" bash "$0"
fi
for command in apt-get curl dpkg timeout; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

TMP="$(mktemp -d /tmp/subyard-zabbly-smoke.XXXXXX)"
chmod 0700 "$TMP"
if [ -f "$KEY" ] && [ ! -L "$KEY" ]; then
  cp -a -- "$KEY" "$TMP/zabbly.asc"
  KEY_EXISTED=1
elif [ -e "$KEY" ] || [ -L "$KEY" ]; then
  die "refusing unsafe existing key path"
fi
if [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
  cp -a -- "$SOURCE" "$TMP/zabbly.sources"
  SOURCE_EXISTED=1
elif [ -e "$SOURCE" ] || [ -L "$SOURCE" ]; then
  die "refusing unsafe existing source path"
fi

# shellcheck source=scripts/lib/ui.sh
. "$ROOT/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/host.sh
. "$ROOT/scripts/lib/host.sh"
# shellcheck source=scripts/e2e-lab/provision.sh
. "$ROOT/scripts/e2e-lab/provision.sh"

assert_key() {
  [ -s "$KEY" ] || die 'caller did not install a non-empty key'
  [ "$(stat -c '%a:%u:%g' "$KEY")" = 644:0:0 ] \
    || die 'caller installed the key with the wrong mode or owner'
  [ -z "$(find /etc/apt/keyrings -maxdepth 1 -name '.zabbly.asc.tmp.*' -print -quit)" ] \
    || die 'caller left a temporary key behind'
}

rm -f -- "$KEY" "$SOURCE"
add_zabbly_lts_repo
assert_key
host_hash="$(sha256sum "$KEY")"
add_zabbly_lts_repo
[ "$(sha256sum "$KEY")" = "$host_hash" ] || die 'host caller changed the converged key'

rm -f -- "$KEY" "$SOURCE"
reconcile_inner_zabbly_repo
assert_key
inner_hash="$(sha256sum "$KEY")"
reconcile_inner_zabbly_repo
[ "$(sha256sum "$KEY")" = "$inner_hash" ] || die 'e2e-lab caller changed the converged key'

printf 'PASS: both Zabbly callers install and converge on a leased disposable VM\n'
