#!/usr/bin/env bash
#
# 01-install-incus.sh — Phase 1: install and initialize Incus for a Subyard yard.
#
# Ensures Incus is present, grants the operator user access to the Incus socket,
# and initializes a minimal Incus with the yard's storage pool under
# $HOME/.subyard. Idempotent: safe to re-run.
#
# Host footprint is kept minimal: only Incus is installed here. We never install
# anything "just in case" — qemu-system (VM mode) is installed lazily by the vm
# path (03-create-subyard.sh) when INSTANCE_TYPE=vm; KVM is diagnosed by
# 00-check-host.sh, so cpu-checker is not needed. Decision #25.
#
# Must run as root (apt + usermod + incus admin init) — the script tells you so
# and prints the exact sudo command if you forget. Announces what it will do and
# asks before proceeding (pass --yes / ASSUME_YES=1 to skip the prompt).
#
# Flags:   -y | --yes   proceed and install without prompting
# Environment (all optional, sane defaults):
#   ASSUME_YES      Same as --yes when set to 1        (default: 0)
#   SUBYARD_USER    Operator user to grant incus-admin (default: $SUDO_USER or invoking user)
#   SUBYARD_HOME    Base dir for yard state            (default: <user home>/.subyard)
#   STORAGE_POOL    Incus storage pool name            (default: default)
#   STORAGE_PATH    dir-backend pool source            (default: $SUBYARD_HOME/storage)
#   INCUS_BRIDGE    Managed bridge name                (default: incusbr0)
#
# Decisions encoded: pool under $HOME/.subyard/storage (#19); incus-admin only to
# the operator's host user (#20); idmapped mounts / SHIFT_MODE=shift (#21);
# minimal host install, detect/advise/offer, nothing "just in case" (#25).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Who gets incus-admin. Under sudo this is $SUDO_USER (the real operator, NOT root);
# falls back to the invoking $USER, and only to 'root' in a bare root shell.
OPERATOR_USER="${SUBYARD_USER:-${SUDO_USER:-${USER:-root}}}"
if [ "$OPERATOR_USER" = root ]; then
  warn "operator user resolved to 'root' (running as root without sudo?); set SUBYARD_USER=<you> to grant your own account"
fi
OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || die "cannot resolve home dir for user '$OPERATOR_USER'"
OPERATOR_GROUP="$(id -gn "$OPERATOR_USER")"

SUBYARD_HOME="${SUBYARD_HOME:-$OPERATOR_HOME/.subyard}"
STORAGE_POOL="${STORAGE_POOL:-default}"
STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME/storage}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"

announce "Subyard Phase 1 — install & initialize Incus" \
  "Install the 'incus' package if missing (apt)." \
  "Add user '$OPERATOR_USER' to group 'incus-admin' — this grants Incus access ≈ root on this host." \
  "Create the storage pool directory: $STORAGE_PATH" \
  "Run 'incus admin init': dir pool '$STORAGE_POOL' + bridge '$INCUS_BRIDGE' (only if not already initialized)."
require_root "the steps above install packages, edit group membership, and initialize Incus"
proceed_or_die

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
  - Phase 1 cont.: scripts/02-create-project.sh (project 'subyard' + restricted config)
MSG
