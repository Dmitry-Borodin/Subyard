#!/usr/bin/env bash
#
# 04-provision-subyard.sh — Phase 3: provision the yard userspace.
#
# Drives provisioning INSIDE the yard via `incus exec`: core packages, Docker
# Engine + Compose (rootful, Stage 1), the unprivileged 'dev' user + groups, the
# /srv skeleton with group-shared permissions, and ssh/docker services. Then,
# back on the host, fixes the /dev/kvm device GID to the in-yard 'kvm' group.
# Idempotent: safe to re-run.
#
# Runs as the operator (incus-admin — no sudo). The in-yard steps run as root
# inside the container, which does not touch host systemd (§20).
#
# Scope = generic core only. Toolchain specifics (JDK, Android SDK, etc.) are
# installed by the dependency profile (Phase 4), NOT here.
# Decision #2: Stage 1 rootful Docker; agents never get the Docker socket.
#
# Config: config/incus.project.env + config/subyard.env (sourced if present).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# --- load config -------------------------------------------------------------
for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"

PROJ=(--project "$INCUS_PROJECT")

# --- preconditions -----------------------------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run scripts/01-install-incus.sh first"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run scripts/03-create-subyard.sh first"

announce_confirm "Subyard Phase 3 — provision the yard ($INSTANCE_NAME)" \
  "Inside the yard: apt-get install core packages (ssh, git, build tools, python, node…)." \
  "Inside the yard: install Docker Engine + Compose via the get.docker.com script (downloads & runs it)." \
  "Inside the yard: create user '$DEV_USER' + groups (yard/kvm/docker), lay out /srv, enable ssh & docker." \
  "On the host: set the /dev/kvm device GID to the in-yard 'kvm' group." \
  "This pulls packages from the network and changes the yard's userspace (not the host system)."

# --- 1. provision inside the yard --------------------------------------------
# Quoted heredoc: nothing expands on the host; vars arrive via --env.
info "provisioning inside $INSTANCE_NAME (packages, Docker, user, /srv, services)"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env DEV_USER="$DEV_USER" -- bash -euo pipefail -s <<'EOS'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Core packages only (toolchain specifics belong to the profile, not core).
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  openssh-server git git-lfs jq rsync make build-essential zip unzip uidmap \
  python3 python3-venv pipx nodejs npm
git lfs install --system >/dev/null 2>&1 || true

# yq (mikefarah single binary; not reliably packaged).
if ! command -v yq >/dev/null 2>&1; then
  arch="$(dpkg --print-architecture)"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
fi

# Docker Engine + Compose plugin (official convenience script; Debian/Ubuntu aware).
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

# Groups + unprivileged dev user (Stage 1: dev is in docker group; agents are not).
groupadd -f yard
groupadd -f kvm
id -u "$DEV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV_USER"
usermod -aG yard,kvm,docker "$DEV_USER"

# /srv skeleton (generic core; profile caches like android-sdk come in Phase 4).
mkdir -p /srv/cache /srv/workspaces /srv/agents /srv/stacks /srv/images /srv/bin
chown -R root:yard /srv
chmod -R g+rwX /srv
find /srv -type d -exec chmod g+s {} \;

# Services live in the container's own systemd (does not touch host systemd).
systemctl enable --now ssh docker
EOS
ok "in-yard provisioning complete"

# --- 2. fix /dev/kvm device GID to the in-yard 'kvm' group --------------------
echo "KVM gid:"
if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx kvm; then
  KVM_GID="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- getent group kvm | cut -d: -f3)"
  if [ -n "${KVM_GID:-}" ]; then
    incus config device set "$INSTANCE_NAME" kvm gid "$KVM_GID" "${PROJ[@]}"
    ok "set kvm device gid=$KVM_GID (matches in-yard 'kvm' group)"
  else
    warn "could not resolve in-yard 'kvm' GID — skipping gid fix"
  fi
else
  ok "no kvm device attached (vm mode or /dev/kvm absent) — nothing to fix"
fi

# --- summary -----------------------------------------------------------------
echo
ok "Phase 3 done."
cat <<MSG

Verify (§21):
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- systemctl --no-pager status ssh docker
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- docker compose version
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- id $DEV_USER          # groups: yard kvm docker
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- ls -la /srv

Next:
  - Phase 4: dependency profile (e.g. android) — caches into /srv/cache (per profile).
  - Phase 7: VS Code / SSH proxy ports.
MSG
