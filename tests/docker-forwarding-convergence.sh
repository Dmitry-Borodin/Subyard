#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export TEST_LOG="$TMP/log"

cat >"$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$TMP/bin/iptables" <<'SH'
#!/bin/sh
case "$*" in
  '-S FORWARD') printf '%s\n' '-P FORWARD DROP' ;;
  *) printf 'iptables %s\n' "$*" >>"$TEST_LOG" ;;
esac
SH
chmod +x "$TMP/bin/systemctl" "$TMP/bin/iptables"
PATH="$TMP/bin:/usr/bin:/bin"
export PATH

docker_function="$TMP/docker-network.sh"
sed -n '/^docker_forwarding_converge()/,/^}/p' \
  "$ROOT/scripts/04-provision-subyard.sh" >"$docker_function"
# shellcheck disable=SC1090
. "$docker_function"

docker_forwarding_converge 0
grep -Fxq 'iptables -P FORWARD ACCEPT' "$TEST_LOG" \
  || { printf 'FAIL: stale FORWARD DROP was not repaired\n' >&2; exit 1; }
! grep -Fq 'systemctl restart docker' "$TEST_LOG" \
  || { printf 'FAIL: unchanged Docker config restarted active workloads\n' >&2; exit 1; }

: >"$TEST_LOG"
docker_forwarding_converge 1
grep -Fxq 'systemctl restart docker' "$TEST_LOG" \
  || { printf 'FAIL: Docker config drift did not trigger restart\n' >&2; exit 1; }

printf 'ok: Docker forwarding convergence\n'
