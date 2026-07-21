#!/usr/bin/env bash
# provision-test-vms-inner.sh — runs as root inside the L1 yard.
# Installs/reconciles the inner Incus VM backend and TTL cleanup service.
set -euo pipefail

[ "$(id -u)" = 0 ] || { printf 'test-vms provision requires root inside the yard\n' >&2; exit 1; }
: "${NESTED_E2E_VMS:=0}"
: "${DEV_USER:=dev}"
: "${E2E_VM_IMAGE:=images:debian/13/cloud}"
: "${E2E_VM_CPU:=2}"
: "${E2E_VM_MEMORY:=4GiB}"
: "${E2E_VM_TTL_MINUTES:=240}"
: "${E2E_VM_BOOT_TIMEOUT:=300}"
: "${E2E_VM_STATE_DIR:=/var/lib/subyard/test-vms}"

case "$NESTED_E2E_VMS" in 0 | 1) ;; *) printf 'invalid NESTED_E2E_VMS\n' >&2; exit 1 ;; esac
[[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid DEV_USER\n' >&2; exit 1; }
[[ "$E2E_VM_CPU" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid E2E_VM_CPU\n' >&2; exit 1; }
[[ "$E2E_VM_MEMORY" =~ ^[1-9][0-9]*(MiB|GiB)$ ]] || { printf 'invalid E2E_VM_MEMORY\n' >&2; exit 1; }
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
E2E_VM_TTL_MINUTES=$E2E_VM_TTL_MINUTES
E2E_VM_BOOT_TIMEOUT=$E2E_VM_BOOT_TIMEOUT
E2E_VM_STATE_DIR=$E2E_VM_STATE_DIR
EOF
chmod 0644 /etc/subyard/test-vms.env

if [ "$NESTED_E2E_VMS" = 0 ]; then
  systemctl disable --now subyard-test-vms-gc.timer >/dev/null 2>&1 || true
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
apt-get install -y -qq incus qemu-system-x86 openssh-client
version_ok || { printf 'Incus 6.0.6 or newer is required inside the yard\n' >&2; exit 1; }
systemctl enable --now incus.service

getent group incus-admin >/dev/null 2>&1 || groupadd --system incus-admin
id -u "$DEV_USER" >/dev/null 2>&1 || { printf 'yard user is missing: %s\n' "$DEV_USER" >&2; exit 1; }
usermod -aG incus-admin "$DEV_USER"
getent group yard >/dev/null 2>&1 || groupadd --system yard
usermod -aG yard "$DEV_USER"
install -d -m 2770 -o root -g yard "$E2E_VM_STATE_DIR"

if ! incus storage show default >/dev/null 2>&1; then
  install -d -m 0711 /srv/incus-e2e/storage
  incus admin init --preseed <<'EOF'
storage_pools:
  - name: default
    driver: dir
    config:
      source: /srv/incus-e2e/storage
networks:
  - name: incusbr0
    type: bridge
    config:
      ipv4.address: auto
      ipv6.address: none
profiles:
  - name: default
    devices:
      root:
        path: /
        pool: default
        type: disk
      eth0:
        name: eth0
        network: incusbr0
        type: nic
EOF
elif ! incus network show incusbr0 >/dev/null 2>&1; then
  if ! output="$(incus network create incusbr0 ipv4.address=auto ipv6.address=none 2>&1)"; then
    case "$output" in
      *"cannot open log"*)
        incus network create incusbr0 ipv4.address=auto ipv6.address=none \
          raw.dnsmasq=log-facility=/var/lib/incus/networks/incusbr0/dnsmasq.log ;;
      *) printf '%s\n' "$output" >&2; exit 1 ;;
    esac
  fi
fi

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
