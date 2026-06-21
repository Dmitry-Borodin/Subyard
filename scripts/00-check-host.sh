#!/usr/bin/env bash
# 00-check-host.sh — Phase 0: report whether the host can run a yard (exit 0 = ready).
# Env: STORAGE_PATH (default /srv), MIN_DISK_GIB (default 50).
set -euo pipefail

case "${1:-}" in
  -h | --help) awk 'NR==1{next} /^#/{sub(/^#[ ]?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

STORAGE_PATH="${STORAGE_PATH:-/srv}"
MIN_DISK_GIB="${MIN_DISK_GIB:-50}"
# Nested Docker (agent machines) needs the Incus AppArmor fix for CVE-2025-52881
# (runc fd-reopen vs the nesting profile); landed in Incus 6.0.6 LTS / 6.19.
MIN_INCUS_VER="${MIN_INCUS_VER:-6.0.6}"

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_OFF=''
fi

fails=0
warns=0

pass() { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; warns=$((warns + 1)); }
fail() { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_OFF" "$*"; fails=$((fails + 1)); }

# --- checks ------------------------------------------------------------------
echo "Subyard host check"
echo

echo "OS:"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "${PRETTY_NAME:-unknown} (kernel $(uname -r))"
else
  fail "cannot read /etc/os-release"
fi

echo "CPU virtualization:"
if grep -Eqc '(vmx|svm)' /proc/cpuinfo; then
  pass "hardware virtualization flags present ($(grep -Ewo 'vmx|svm' /proc/cpuinfo | sort -u | tr '\n' ' '))"
else
  warn "no vmx/svm flags — VM mode and the hardware-accelerated emulator will not work"
fi

echo "KVM device:"
if [ -e /dev/kvm ]; then
  pass "/dev/kvm present"
else
  warn "/dev/kvm missing — needed for VM mode and the Android emulator"
fi

echo "Resources:"
if command -v nproc >/dev/null 2>&1; then
  pass "$(nproc) CPU(s)"
else
  warn "nproc not available"
fi
if [ -r /proc/meminfo ]; then
  mem_gib=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
  pass "${mem_gib} GiB RAM"
else
  warn "cannot read /proc/meminfo"
fi

echo "Storage (${STORAGE_PATH}):"
probe="$STORAGE_PATH"
while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
  probe=$(dirname "$probe")
done
if df -BG --output=avail,fstype "$probe" >/dev/null 2>&1; then
  read -r avail fstype <<EOF
$(df -BG --output=avail,fstype "$probe" | tail -1)
EOF
  avail_gib=${avail%G}
  if [ "${avail_gib:-0}" -ge "$MIN_DISK_GIB" ]; then
    pass "${avail_gib} GiB free on ${probe} (fs: ${fstype})"
  else
    fail "only ${avail_gib} GiB free on ${probe}; need >= ${MIN_DISK_GIB} GiB (fs: ${fstype})"
  fi
else
  warn "cannot determine free space for ${probe}"
fi

echo "Existing tools:"
if command -v incus >/dev/null 2>&1; then
  iver="$(incus --version 2>/dev/null || echo '?')"
  pass "incus present ($iver)"
  # Warn if older than the nested-Docker fix (agent machines won't run otherwise).
  if [ "$iver" != '?' ] && command -v dpkg >/dev/null 2>&1 \
     && ! dpkg --compare-versions "$iver" ge "$MIN_INCUS_VER"; then
    warn "incus $iver < $MIN_INCUS_VER — nested Docker (yard agent) fails until you upgrade"
    warn "  (Ubuntu ships only 6.0.0; use the Zabbly LTS-6.0 repo for >= $MIN_INCUS_VER)"
  fi
else
  warn "incus not installed — install in Phase 1 (01-install-incus.sh)"
fi
if command -v docker >/dev/null 2>&1; then
  warn "docker present on host — Subyard runs Docker inside the yard, not on the host"
else
  pass "no host Docker (expected; Docker lives inside the yard)"
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  printf '%sHost is ready.%s' "$C_OK" "$C_OFF"
  [ "$warns" -gt 0 ] && printf ' (%d warning(s))' "$warns"
  echo
  exit 0
else
  printf '%sHost is not ready: %d hard requirement(s) failed, %d warning(s).%s\n' \
    "$C_BAD" "$fails" "$warns" "$C_OFF"
  exit 1
fi
