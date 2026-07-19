#!/usr/bin/env bash
# Install a missing OpenCode CLI as DEV_USER and expose it on the yard PATH.
set -euo pipefail

DEV_USER="${DEV_USER:-dev}"
INSTALL_URL="${OPENCODE_INSTALL_URL:-https://opencode.ai/install}"
DEV_HOME="${OPENCODE_INSTALL_HOME:-$(getent passwd "$DEV_USER" | cut -d: -f6)}"
: "${DEV_HOME:=/home/$DEV_USER}"
INSTALL_BIN="${OPENCODE_INSTALL_BIN:-$DEV_HOME/.opencode/bin/opencode}"
BIN_LINK="${OPENCODE_BIN_LINK:-/usr/local/bin/opencode}"
SYSTEM_PATH="${OPENCODE_SYSTEM_PATH:-/usr/local/bin:/usr/bin:/bin}"

die() { printf 'OpenCode provision: %s\n' "$*" >&2; exit 1; }

run_as_dev() {
  if [ "$(id -un)" = "$DEV_USER" ]; then
    env HOME="$DEV_HOME" SHELL=/bin/bash \
      PATH="$DEV_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  else
    command -v runuser >/dev/null 2>&1 || die "runuser is required to install as $DEV_USER"
    runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" SHELL=/bin/bash \
      PATH="$DEV_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  fi
}

# Keep existing installs.
if [ -x "$BIN_LINK" ]; then
  printf 'OpenCode already available at %s — keeping it\n' "$BIN_LINK"
  exit 0
fi
existing="$(PATH="$SYSTEM_PATH" command -v opencode 2>/dev/null || true)"
if [ -n "$existing" ] && [ -x "$existing" ]; then
  printf 'OpenCode already available at %s — keeping it\n' "$existing"
  exit 0
fi

if [ ! -x "$INSTALL_BIN" ]; then
  printf 'Installing OpenCode for %s with the official installer\n' "$DEV_USER"
  curl -fsSL "$INSTALL_URL" | run_as_dev bash -s -- --no-modify-path
fi
[ -x "$INSTALL_BIN" ] || die "installer did not create $INSTALL_BIN"

# The stable link works for non-login launches without editing shell rc files.
if [ -L "$BIN_LINK" ]; then
  [ "$(readlink "$BIN_LINK")" = "$INSTALL_BIN" ] \
    || die "$BIN_LINK is a symlink managed by another install — leaving it unchanged"
elif [ -e "$BIN_LINK" ]; then
  die "$BIN_LINK already exists and is not executable — leaving it unchanged"
else
  mkdir -p "$(dirname "$BIN_LINK")"
  ln -s "$INSTALL_BIN" "$BIN_LINK"
fi

run_as_dev "$BIN_LINK" --version >/dev/null
printf 'OpenCode is ready at %s\n' "$BIN_LINK"
