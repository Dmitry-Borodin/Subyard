#!/usr/bin/env bash
# 00-check-host.sh — Phase 0: report whether the host can run a yard (exit 0 = ready).
# Env: STORAGE_PATH (default $SUBYARD_HOME/incus/storage), MIN_DISK_GIB (hard floor, default 20),
#      REC_DISK_GIB (recommended for the heavy 'android' profile, default 50).
set -euo pipefail

case "${1:-}" in
  -h | --help) awk 'NR==1{next} /^#/{sub(/^#[ ]?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

# Load the explicit yard context + registry helpers used by the port-collision preflight.
# The local pass/warn/fail helpers are (re)defined AFTER this so the check counters keep working
# (ui.sh's own warn() does not count).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

# --- remote context: probe the owner host, skip the local host checks ------------------------
# `yard -Y <remote> check` runs HERE, but the checks below measure THIS controller — meaningless
# for a yard on another machine. Short-circuit to a lightweight probe (reachability + _info parse
# + CLI version drift) and exit. Uses ui.sh's info/ok/warn/die.
if [ "${YARD_TYPE:-local}" = remote ]; then
  dest="${REMOTE_DEST:-}"; ryard="${REMOTE_YARD:-}"
  [ -n "$dest" ] || die "remote yard '${YARD_NAME:-?}' has no REMOTE_DEST — re-run 'yard remote add'"
  echo "Subyard remote check: ${YARD_NAME:-?} -> $dest${ryard:+ (yard $ryard)}"
  echo
  rc='yard _info'; [ -n "$ryard" ] && rc="yard -Y $(printf '%q' "$ryard") _info"
  json="$(ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_REMOTE_TIMEOUT:-10}" \
          -o StrictHostKeyChecking=accept-new "$dest" -- bash -lc "$(printf '%q' "$rc")" 2>/dev/null)" || json=''
  case "$json" in
    '{'*'}') ok "reachable: $dest answered 'yard _info'" ;;
    *) die "cannot reach '$dest' or run 'yard _info' there — check ssh access and that the owner host is up" ;;
  esac
  state="$(printf '%s' "$json" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p' | head -n1)"
  rver="$(printf '%s' "$json" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n1)"
  case "$state" in
    RUNNING)     ok "remote yard state: RUNNING" ;;
    ''|UNKNOWN)  warn "remote yard state unknown (owner host reachable; its incus is not answering)" ;;
    *)           warn "remote yard state: $state — start it: ssh $dest -- yard ${ryard:+-Y $ryard }start" ;;
  esac
  if [ -n "$rver" ] && [ "$rver" != "${YARD_VERSION:-}" ]; then
    warn "version drift: remote $rver vs local ${YARD_VERSION:-?} (forwarded commands run the remote CLI)"
  else
    ok "CLI version matches (${YARD_VERSION:-?})"
  fi
  echo
  ok "Remote yard reachable."
  exit 0
fi

MIN_DISK_GIB="${MIN_DISK_GIB:-20}"   # hard floor: a base yard won't fit below this
REC_DISK_GIB="${REC_DISK_GIB:-50}"   # recommended: the 'android' profile (SDK/AVD) is heavy
# Nested Docker (project-env boxes) needs the Incus AppArmor fix for CVE-2025-52881
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

if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
  echo "Nested E2E VM devices:"
  for node in /dev/kvm /dev/vsock /dev/vhost-vsock /dev/net/tun; do
    if [ -c "$node" ]; then
      pass "$node present"
    else
      fail "$node missing — NESTED_E2E_VMS=1 cannot work; load kvm/vhost_vsock on L0 or disable the capability"
    fi
  done
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
  if [ "${avail_gib:-0}" -ge "$REC_DISK_GIB" ]; then
    pass "${avail_gib} GiB free on ${probe} (fs: ${fstype})"
  elif [ "${avail_gib:-0}" -ge "$MIN_DISK_GIB" ]; then
    warn "${avail_gib} GiB free on ${probe} — ok for a base yard, but the heavy 'android' profile wants >= ${REC_DISK_GIB} GiB (fs: ${fstype})"
  else
    fail "only ${avail_gib} GiB free on ${probe}; need >= ${MIN_DISK_GIB} GiB for a base yard (fs: ${fstype})"
  fi
else
  warn "cannot determine free space for ${probe}"
fi

echo "Existing tools:"
if command -v incus >/dev/null 2>&1; then
  iver="$(incus --version 2>/dev/null || echo '?')"
  pass "incus present ($iver)"
  # Warn if older than the nested-Docker fix (project-env boxes won't run otherwise).
  if [ "$iver" != '?' ] && command -v dpkg >/dev/null 2>&1 \
     && ! dpkg --compare-versions "$iver" ge "$MIN_INCUS_VER"; then
    warn "incus $iver < $MIN_INCUS_VER — nested Docker (project-env boxes) fails until you upgrade"
    warn "  ${PRETTY_NAME:-your distro} packages incus $iver — 'yard init' offers to add the Zabbly LTS-6.0 repo and upgrade"
  fi
else
  warn "incus not installed — install in Phase 1 (01-install-incus.sh)"
fi
if command -v docker >/dev/null 2>&1; then
  warn "docker present on host — Subyard runs Docker inside the yard, not on the host"
else
  pass "no host Docker (expected; Docker lives inside the yard)"
fi

# --- yard SSH port collision -------------------------------------------------
# Each yard needs its OWN host loopback port for the ssh proxy device. Compare this context's
# SSH_PORT against every other configured yard and the default yard's port. A duplicate is fatal
# only under SUBYARD_PREFLIGHT_STRICT=1 (set by 'yard init'); a plain 'yard check' warns. The
# listening probe is advisory (it also trips when this yard is already running — not a conflict).
echo "Yard SSH port:"
our_port="${SSH_PORT:-}"
me="${YARD_NAME:-default}"
# The default yard's port comes from config, not a yard file — resolve it once, cleanly.
# shellcheck disable=SC1091
default_port="$(unset SSH_PORT SUBYARD_YARD; . "$SCRIPT_DIR/../config/subyard.env" >/dev/null 2>&1; printf '%s' "${SSH_PORT:-}")"
if [ -z "$our_port" ]; then
  warn "no SSH_PORT resolved for this context — a local yard must declare one"
else
  dups=''
  while IFS= read -r yn; do
    [ -n "$yn" ] || continue
    [ "$yn" = "$me" ] && continue
    if [ "$yn" = default ]; then
      yp="$default_port"
    else
      yf="$(yard_env_file "$yn" 2>/dev/null)" || continue
      # A REMOTE yard's SSH_PORT is a port on the OWNER host, not this loopback — comparing it
      # against a local port is a false collision. Emit nothing for YARD_TYPE=remote (an empty
      # yp is not counted as a duplicate below).
      # shellcheck disable=SC1090
      yp="$(unset SSH_PORT SUBYARD_YARD YARD_TYPE
            . "$yf" >/dev/null 2>&1
            [ "${YARD_TYPE:-local}" = remote ] && exit 0
            printf '%s' "${SSH_PORT:-}")"
    fi
    [ -n "$yp" ] && [ "$yp" = "$our_port" ] && dups="$dups $yn"
  done < <(yard_registry_names)
  if [ -n "$dups" ]; then
    if [ "${SUBYARD_PREFLIGHT_STRICT:-0}" = 1 ]; then
      fail "SSH_PORT $our_port also used by yard(s):$dups — give each yard a unique host loopback port"
    else
      warn "SSH_PORT $our_port also used by yard(s):$dups — give each yard a unique host loopback port"
    fi
  else
    pass "SSH_PORT $our_port is unique across configured yards"
  fi
  # Loopback listening probe (advisory): is something already bound to our port?
  if command -v ss >/dev/null 2>&1; then
    inuse=0
    while IFS= read -r la; do case "$la" in *:"$our_port") inuse=1 ;; esac; done \
      < <(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}')
    if [ "$inuse" = 1 ]; then
      warn "host port $our_port is already listening (another service, or this yard is already running)"
    else
      pass "host loopback port $our_port is free"
    fi
  fi
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
