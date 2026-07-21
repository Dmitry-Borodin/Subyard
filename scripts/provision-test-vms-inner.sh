#!/usr/bin/env bash
# provision-test-vms-inner.sh — runs as root inside the L1 yard.
# Installs/reconciles the inner Incus VM backend and TTL cleanup service.
set -euo pipefail

inner_incus() {
  # This provisioner is executed with `bash -s`, so its stdin is the script body itself. Incus
  # create commands accept YAML on stdin; never let a child consume the remaining shell program.
  incus "$@" </dev/null
}

inner_apparmor_dropin() {
  printf '%s\n' "${SUBYARD_INNER_INCUS_APPARMOR_DROPIN:-/etc/systemd/system/incus.service.d/subyard-nested-e2e.conf}"
}

reconcile_inner_apparmor_compat() {
  local dropin temp changed=0
  dropin="$(inner_apparmor_dropin)"
  install -d -m 0755 "$(dirname "$dropin")"
  temp="$(mktemp)"
  printf '%s\n' \
    '# Managed by Subyard: the outer yard profile remains the L0 security boundary.' \
    '[Service]' \
    'Environment=INCUS_SECURITY_APPARMOR=false' > "$temp"
  if ! cmp -s "$temp" "$dropin"; then
    install -m 0644 "$temp" "$dropin"
    changed=1
  fi
  rm -f "$temp"

  systemctl daemon-reload
  systemctl enable incus.service >/dev/null
  if [ "$changed" = 1 ] && systemctl is-active --quiet incus.service; then
    # Incus reads INCUS_SECURITY_APPARMOR only at daemon startup. QEMU processes are independent
    # of the daemon, so this does not stop an already-running VM during an idempotent init rerun.
    systemctl restart incus.service
  else
    systemctl start incus.service
  fi
}

restore_inner_apparmor_default() {
  local dropin
  dropin="$(inner_apparmor_dropin)"
  [ -e "$dropin" ] || return 0
  rm -f "$dropin"
  systemctl daemon-reload
  if systemctl is-active --quiet incus.service; then
    systemctl restart incus.service
  fi
}

reconcile_inner_incus() {
  local output

  # Build the three bootstrap resources independently so a network failure never strands the
  # daemon halfway through one monolithic `incus admin init`. Nested AppArmor can deny dnsmasq's
  # syslog socket; retry that one resource with a log inside Incus' own allowed state directory.
  install -d -m 0711 /srv/incus-e2e/storage
  if ! inner_incus storage show default --project default >/dev/null 2>&1; then
    inner_incus storage create default dir source=/srv/incus-e2e/storage --project default
  fi

  if ! inner_incus network show incusbr0 --project default >/dev/null 2>&1; then
    if ! output="$(inner_incus network create incusbr0 ipv4.address=auto ipv6.address=none \
      --project default 2>&1)"; then
      case "$output" in
        *"cannot open log"*)
          inner_incus network create incusbr0 ipv4.address=auto ipv6.address=none \
            raw.dnsmasq=log-facility=/var/lib/incus/networks/incusbr0/dnsmasq.log \
            --project default ;;
        *) printf '%s\n' "$output" >&2; return 1 ;;
      esac
    fi
  fi

  inner_incus profile show default --project default >/dev/null 2>&1 \
    || inner_incus profile create default --project default
  if ! inner_incus profile device list default --project default 2>/dev/null | grep -qx root; then
    inner_incus profile device add default root disk pool=default path=/ --project default
  fi
  if ! inner_incus profile device list default --project default 2>/dev/null | grep -qx eth0; then
    inner_incus profile device add default eth0 nic network=incusbr0 --project default
  fi
}

# Production streams this file into L1 with `bash -s`, where BASH_SOURCE has no element 0. Treat
# that as execution; return early only when a test explicitly sources the file from another script.
[ "${BASH_SOURCE[0]:-$0}" = "$0" ] || return 0

[ "$(id -u)" = 0 ] || { printf 'test-vms provision requires root inside the yard\n' >&2; exit 1; }
: "${NESTED_E2E_VMS:=0}"
: "${DEV_USER:=dev}"
: "${E2E_VM_IMAGE:=images:debian/13/cloud}"
: "${E2E_VM_CPU:=2}"
: "${E2E_VM_MEMORY:=4GiB}"
: "${E2E_VM_DISK:=30GiB}"
: "${E2E_VM_TTL_MINUTES:=240}"
: "${E2E_VM_BOOT_TIMEOUT:=300}"
: "${E2E_VM_STATE_DIR:=/var/lib/subyard/test-vms}"

case "$NESTED_E2E_VMS" in 0 | 1) ;; *) printf 'invalid NESTED_E2E_VMS\n' >&2; exit 1 ;; esac
[[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid DEV_USER\n' >&2; exit 1; }
[[ "$E2E_VM_CPU" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid E2E_VM_CPU\n' >&2; exit 1; }
[[ "$E2E_VM_MEMORY" =~ ^[1-9][0-9]*(MiB|GiB)$ ]] || { printf 'invalid E2E_VM_MEMORY\n' >&2; exit 1; }
[[ "$E2E_VM_DISK" =~ ^[1-9][0-9]*(MiB|GiB)$ ]] || { printf 'invalid E2E_VM_DISK\n' >&2; exit 1; }
case "$E2E_VM_DISK" in
  *GiB) e2e_disk_mib=$(( ${E2E_VM_DISK%GiB} * 1024 )) ;;
  *MiB) e2e_disk_mib=${E2E_VM_DISK%MiB} ;;
esac
[ "$e2e_disk_mib" -ge 24576 ] \
  || { printf 'E2E_VM_DISK must be at least 24GiB\n' >&2; exit 1; }
case "$E2E_VM_IMAGE" in '' | -* | *[!A-Za-z0-9._:/@+-]*) printf 'invalid E2E_VM_IMAGE\n' >&2; exit 1 ;; esac
[[ "$E2E_VM_TTL_MINUTES" =~ ^[0-9]+$ ]] \
  && [ "$E2E_VM_TTL_MINUTES" -ge 15 ] && [ "$E2E_VM_TTL_MINUTES" -le 1440 ] \
  || { printf 'invalid E2E_VM_TTL_MINUTES\n' >&2; exit 1; }
[[ "$E2E_VM_BOOT_TIMEOUT" =~ ^[0-9]+$ ]] \
  && [ "$E2E_VM_BOOT_TIMEOUT" -ge 30 ] && [ "$E2E_VM_BOOT_TIMEOUT" -le 1800 ] \
  || { printf 'invalid E2E_VM_BOOT_TIMEOUT\n' >&2; exit 1; }
case "$E2E_VM_STATE_DIR" in /var/lib/subyard/*) ;; *) printf 'unsafe E2E_VM_STATE_DIR\n' >&2; exit 1 ;; esac

install -d -m 0755 /etc/subyard
cat > /etc/subyard/test-vms.env <<EOF
NESTED_E2E_VMS=$NESTED_E2E_VMS
DEV_USER=$DEV_USER
E2E_VM_IMAGE=$E2E_VM_IMAGE
E2E_VM_CPU=$E2E_VM_CPU
E2E_VM_MEMORY=$E2E_VM_MEMORY
E2E_VM_DISK=$E2E_VM_DISK
E2E_VM_TTL_MINUTES=$E2E_VM_TTL_MINUTES
E2E_VM_BOOT_TIMEOUT=$E2E_VM_BOOT_TIMEOUT
E2E_VM_STATE_DIR=$E2E_VM_STATE_DIR
EOF
chmod 0644 /etc/subyard/test-vms.env

if [ "$NESTED_E2E_VMS" = 0 ]; then
  systemctl disable --now subyard-test-vms-gc.timer >/dev/null 2>&1 || true
  restore_inner_apparmor_default
  exit 0
fi

for node in /dev/kvm /dev/vsock /dev/vhost-vsock /dev/net/tun; do
  [ -c "$node" ] || { printf 'nested VM device missing inside yard: %s\n' "$node" >&2; exit 1; }
done

version_ok() {
  command -v incus >/dev/null 2>&1 \
    && dpkg --compare-versions "$(incus --version 2>/dev/null)" ge 6.0.6
}

if ! version_ok; then
  suite="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  [ -n "$suite" ] || { printf 'cannot resolve apt suite for the Incus LTS repository\n' >&2; exit 1; }
  arch="$(dpkg --print-architecture)"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
  chmod 0644 /etc/apt/keyrings/zabbly.asc
  cat > /etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-6.0
Suites: $suite
Components: main
Architectures: $arch
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq incus qemu-system-x86 openssh-client golang-go shellcheck
version_ok || { printf 'Incus 6.0.6 or newer is required inside the yard\n' >&2; exit 1; }
# AppArmor 4.1 userspace emits AF_UNIX rules that the 6.8 kernel rejects with a type/protocol ABI
# mismatch. Disable only the inner daemon's per-instance profiles. The trusted L1 container remains
# confined by its L0 AppArmor profile and the inner daemon has no L0 socket or host paths.
reconcile_inner_apparmor_compat

getent group incus-admin >/dev/null 2>&1 || groupadd --system incus-admin
id -u "$DEV_USER" >/dev/null 2>&1 || { printf 'yard user is missing: %s\n' "$DEV_USER" >&2; exit 1; }
usermod -aG incus-admin "$DEV_USER"
getent group yard >/dev/null 2>&1 || groupadd --system yard
usermod -aG yard "$DEV_USER"
install -d -m 2770 -o root -g yard "$E2E_VM_STATE_DIR"

reconcile_inner_incus

cat > /etc/systemd/system/subyard-test-vms-gc.service <<'EOF'
[Unit]
Description=Remove expired Subyard disposable test VMs
After=incus.service
Requires=incus.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/subyard/test-vms-inner gc
EOF
cat > /etc/systemd/system/subyard-test-vms-gc.timer <<'EOF'
[Unit]
Description=Check Subyard disposable test VM TTL

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now subyard-test-vms-gc.timer
