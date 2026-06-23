#!/usr/bin/env bash
# 01-install-incus.sh — Phase 1: install Incus, grant the operator incus-admin,
# init a dir pool under $HOME/.subyard. Idempotent. Self-elevates via sudo.
# Only `incus` is installed here (qemu is lazy in vm mode).
# Env: SUBYARD_USER, SUBYARD_HOME, STORAGE_POOL, STORAGE_PATH, INCUS_BRIDGE; flag -y.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Grant incus-admin to the real operator (SUDO_USER under sudo), not root.
OPERATOR_USER="${SUBYARD_USER:-${SUDO_USER:-${USER:-root}}}"
if [ "$OPERATOR_USER" = root ]; then
  warn "operator user resolved to 'root' (running as root without sudo?); set SUBYARD_USER=<you> to grant your own account"
fi
OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || die "cannot resolve home dir for user '$OPERATOR_USER'"
OPERATOR_GROUP="$(id -gn "$OPERATOR_USER")"

# $SUBYARD_HOME is already resolved under the real operator by lib.sh's auto-load (it reads
# the same SUDO_USER), so it points at the operator's home even though this script self-elevates.
STORAGE_POOL="${STORAGE_POOL:-default}"
STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME/storage}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"

announce "Subyard Phase 1 — install & initialize Incus" \
  "Install the 'incus' package if missing (apt)." \
  "Add user '$OPERATOR_USER' to group 'incus-admin' — this grants Incus access ≈ root on this host." \
  "Create the storage pool directory: $STORAGE_PATH" \
  "Run 'incus admin init': dir pool '$STORAGE_POOL' + bridge '$INCUS_BRIDGE' (only if not already initialized)."
proceed_or_die
require_root "the steps above install packages, edit group membership, and initialize Incus"

# --- 1. ensure incus (the only host package we install here) -----------------
echo "Dependency: incus"
if command -v incus >/dev/null 2>&1; then
  ok "incus present ($(incus --version 2>/dev/null || echo '?'))"
else
  command -v apt-get >/dev/null 2>&1 \
    || die "no apt-get; install Incus manually (linuxcontainers.org/incus) and re-run"
  warn "missing dependency: incus — installing (sudo apt-get install incus)"
  info "apt-get update"
  apt-get update -qq
  info "installing incus"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq incus \
    || die "incus install failed (on noble/Trixie it is in the distro repos; Zabbly is an alternative)"
  ok "incus installed ($(incus --version 2>/dev/null || echo '?'))"
fi

# --- 2. grant operator access to the Incus socket ---------------------------
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

# --- 5. keep NetworkManager off Incus bridge/veths (host-internet guard) ------
# Set up BEFORE any instance/veth exists, so NM never grabs a yard veth.
echo "Host networking (NetworkManager guard):"
nm_unmanaged_guard "$INCUS_BRIDGE"

# --- summary -----------------------------------------------------------------
echo
ok "Phase 1 done."
cat <<MSG

Next:
  - Re-login (or run 'newgrp incus-admin') so $OPERATOR_USER can use 'incus'
    without sudo, then verify:  incus list
  - Phase 1 cont.: scripts/02-create-project.sh (project 'subyard' + restricted config)
MSG
