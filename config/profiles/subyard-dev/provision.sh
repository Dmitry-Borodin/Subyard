#!/usr/bin/env bash
# Install the L1 development toolchain for Subyard. Debian Go is only the bootstrap; the repository
# go.mod selects and downloads the exact compiler into the persistent module cache.
set -euo pipefail

if [ "$(id -u)" -ne 0 ] && [ "${SUBYARD_DEV_TEST_ALLOW_NON_ROOT:-0}" != 1 ]; then
  printf 'subyard-dev provision: must run as root\n' >&2
  exit 1
fi

DEV_USER="${DEV_USER:-dev}"
DEV_GROUP="${DEV_GROUP:-$(id -gn "$DEV_USER")}"
DEV_HOME="${SUBYARD_DEV_HOME:-$(getent passwd "$DEV_USER" | cut -d: -f6)}"
DEV_HOME="${DEV_HOME:-/home/$DEV_USER}"
GOCACHE="${GOCACHE:-/srv/cache/go-build}"
GOMODCACHE="${GOMODCACHE:-/srv/cache/go-mod}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq golang-go shellcheck

install -d -o "$DEV_USER" -g "$DEV_GROUP" "$GOCACHE" "$GOMODCACHE" "$DEV_HOME/.config/go"

run_as_dev() {
  if [ "$(id -un)" = "$DEV_USER" ]; then
    HOME="$DEV_HOME" "$@"
  else
    runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" "$@"
  fi
}

run_as_dev go env -w GOCACHE="$GOCACHE" GOMODCACHE="$GOMODCACHE" GOTOOLCHAIN=auto
run_as_dev go env GOCACHE GOMODCACHE GOTOOLCHAIN
printf 'subyard-dev provision OK: %s; shellcheck %s\n' \
  "$(run_as_dev go version)" "$(shellcheck --version | awk '/^version:/ { print $2; exit }')"
