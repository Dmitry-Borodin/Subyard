#!/usr/bin/env bash
#
# 01-install-incus.sh — Phase 1: install and initialize Incus for a Subyard yard.
#
# Installs Incus (and best-effort VM/KVM tooling), grants the operator user
# access to the Incus socket, and initializes a minimal Incus with the yard's
# storage pool under $HOME/.subyard. Idempotent: safe to re-run.
#
# Must run as root (apt + usermod + incus admin init). Re-run with sudo.
#
# Environment (all optional, sane defaults):
#   SUBYARD_USER    Operator user to grant incus-admin (default: $SUDO_USER or invoking user)
#   SUBYARD_HOME    Base dir for yard state            (default: <user home>/.subyard)
#   STORAGE_POOL    Incus storage pool name            (default: default)
#   STORAGE_PATH    dir-backend pool source            (default: $SUBYARD_HOME/storage)
#   INCUS_BRIDGE    Managed bridge name                (default: incusbr0)
#
# Decisions encoded: pool under $HOME/.subyard/storage (#19); incus-admin only
# to the operator's host user (#20); idmapped mounts / SHIFT_MODE=shift (#21).
#
set -euo pipefail

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_OFF=''
fi
info() { printf '  %s[ .. ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root — re-run with: sudo $0"

OPERATOR_USER="${SUBYARD_USER:-${SUDO_USER:-root}}"
if [ "$OPERATOR_USER" = root ]; then
  warn "operator user resolved to 'root'; set SUBYARD_USER=<you> to grant your own account instead"
fi

OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || die "cannot resolve home dir for user '$OPERATOR_USER'"
OPERATOR_GROUP="$(id -gn "$OPERATOR_USER")"

SUBYARD_HOME="${SUBYARD_HOME:-$OPERATOR_HOME/.subyard}"
STORAGE_POOL="${STORAGE_POOL:-default}"
STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME/storage}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"

echo "Subyard Incus install (Phase 1)"
echo "  operator user : $OPERATOR_USER"
echo "  pool source   : $STORAGE_PATH (driver: dir)"
echo

# --- 1. install packages -----------------------------------------------------
echo "Packages:"
if command -v incus >/dev/null 2>&1; then
  ok "incus already installed ($(incus --version 2>/dev/null || echo '?'))"
else
  command -v apt-get >/dev/null 2>&1 \
    || die "no apt-get; install Incus manually (see linuxcontainers.org/incus) and re-run"
  info "apt-get update"
  apt-get update -qq
  info "installing incus"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq incus \
    || die "failed to install incus (on noble/Trixie it is in the distro repos; Zabbly repo is an alternative)"
  ok "incus installed ($(incus --version 2>/dev/null || echo '?'))"
fi

# VM mode + KVM tooling are best-effort (only needed for INSTANCE_TYPE=vm / emulator).
for pkg in qemu-system-x86 cpu-checker; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg present"
  elif DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
    ok "$pkg installed"
  else
    warn "$pkg not installed (only needed for VM mode / emulator) — skipping"
  fi
done

# --- 2. grant operator access to the Incus socket (#20) ----------------------
echo "Socket access (incus-admin → operator only):"
if ! getent group incus-admin >/dev/null 2>&1; then
  warn "group 'incus-admin' missing; creating it"
  groupadd --system incus-admin
fi
if id -nG "$OPERATOR_USER" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; then
  ok "$OPERATOR_USER already in incus-admin"
else
  usermod -aG incus-admin "$OPERATOR_USER"
  ok "added $OPERATOR_USER to incus-admin (re-login required to take effect)"
fi

# --- 3. storage dir ----------------------------------------------------------
echo "Storage:"
if [ ! -d "$STORAGE_PATH" ]; then
  install -d -o "$OPERATOR_USER" -g "$OPERATOR_GROUP" "$STORAGE_PATH"
  ok "created $STORAGE_PATH"
else
  ok "$STORAGE_PATH exists"
fi

# --- 4. initialize Incus (idempotent) ----------------------------------------
echo "Init:"
if incus storage show "$STORAGE_POOL" >/dev/null 2>&1; then
  ok "Incus already initialized (pool '$STORAGE_POOL' exists) — leaving as-is"
else
  info "running incus admin init (pool '$STORAGE_POOL' → $STORAGE_PATH)"
  incus admin init --preseed <<EOF
storage_pools:
  - name: $STORAGE_POOL
    driver: dir
    config:
      source: $STORAGE_PATH
networks:
  - name: $INCUS_BRIDGE
    type: bridge
    config:
      ipv4.address: auto
      ipv6.address: none
profiles:
  - name: default
    devices:
      root:
        path: /
        pool: $STORAGE_POOL
        type: disk
      eth0:
        name: eth0
        network: $INCUS_BRIDGE
        type: nic
EOF
  ok "Incus initialized"
fi

# --- summary -----------------------------------------------------------------
echo
ok "Phase 1 done."
cat <<MSG

Next:
  - Re-login (or run 'newgrp incus-admin') so $OPERATOR_USER can use 'incus'
    without sudo, then verify:  incus list
  - Phase 1 cont.: scripts/02-create-project.sh (project 'agent-dev' + restricted config)
MSG
