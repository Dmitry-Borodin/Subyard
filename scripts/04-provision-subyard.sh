#!/usr/bin/env bash
# 04-provision-subyard.sh — Phase 3: provision the yard via `incus exec` (core pkgs,
# Docker Stage 1, user 'dev', /srv layout, ssh/docker) + host-side kvm-gid fix. Idempotent.
# Core only — toolchain is per-profile (Phase 4). Agents never get the Docker socket.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"

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
  "On the host: copy your CLAUDE.md into the yard (config HOST_CLAUDE_MD), if present." \
  "This pulls packages from the network and changes the yard's userspace (not the host system)."

# --- 1. provision inside the yard --------------------------------------------
# Quoted heredoc: nothing expands on the host; vars arrive via --env.
info "provisioning inside $INSTANCE_NAME (packages, Docker, user, /srv, services)"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env DEV_USER="$DEV_USER" --env DEV_UID="$DEV_UID" --env HOST_LINKS="${HOST_LINKS:-}" -- bash -euo pipefail -s <<'EOS'
export DEBIAN_FRONTEND=noninteractive
# The yard bridge is IPv4-only (ipv6.address=none), so steer apt to IPv4 — mirrors that
# resolve to AAAA records would otherwise be tried over an unreachable IPv6 path first.
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
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
# dev's uid is pinned to DEV_UID so it lines up with the shift-mapped host-mount owner.
groupadd -f yard
groupadd -f kvm
if ! id -u "$DEV_USER" >/dev/null 2>&1; then
  useradd -u "$DEV_UID" -m -s /bin/bash "$DEV_USER" \
    || { echo "uid $DEV_UID is taken in the yard — set a free DEV_UID in config/subyard.env" >&2; exit 1; }
elif [ "$(id -u "$DEV_USER")" != "$DEV_UID" ]; then
  echo "WARNING: $DEV_USER uid $(id -u "$DEV_USER") != DEV_UID $DEV_UID — host mounts won't map to $DEV_USER" >&2
fi
usermod -aG yard,kvm,docker "$DEV_USER"

# Coding-agent state. Credentials live per-yard in rootfs (~/.claude, ~/.codex) and are
# never shared with the host; only sessions are shared via HOST_LINKS (below), pointing
# ~/.claude/projects and ~/.codex/sessions at the host-agent-sessions mount. CLAUDE.md is
# copied in host-side (section 3), not symlinked.
dev_home="$(getent passwd "$DEV_USER" | cut -d: -f6)"

# Agent homes are real rootfs dirs (creds land here). Drop any stale symlink so
# re-provisioning a previously-shared yard is clean.
for d in .claude .codex; do
  p="$dev_home/$d"
  [ -L "$p" ] && rm -f "$p"
  runuser -u "$DEV_USER" -- mkdir -p "$p"
done

# Host-backed symlinks in dev's $HOME (declared by HOST_LINKS in config/host.env): each
# entry "<name under $HOME>:<target in yard>" points a path at a host<->yard mount — used
# for SESSIONS only now (e.g. .claude/projects -> the host-agent-sessions mount).
# Idempotent; ensures the link's parent exists; skips an entry whose mount (by convention
# /mnt/host/<name>) isn't attached; never clobbers a real directory that already holds data.
if [ -n "${HOST_LINKS:-}" ]; then
  printf '%s\n' "$HOST_LINKS" | sed 's/[[:space:]]//g' | while IFS=: read -r name target; do
    [ -n "$name" ] && [ -n "$target" ] || continue
    mroot="/$(printf '%s' "$target" | cut -d/ -f2-4)"
    [ -d "$mroot" ] || { echo "skip $name -> $target (host mount $mroot not attached)" >&2; continue; }
    runuser -u "$DEV_USER" -- mkdir -p "$target" 2>/dev/null || true
    link="$dev_home/$name"
    runuser -u "$DEV_USER" -- mkdir -p "$(dirname "$link")" 2>/dev/null || true
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      ln -sfn "$target" "$link"; chown -h "$DEV_USER:$DEV_USER" "$link"
    else
      echo "WARNING: $link exists and is not a symlink — leaving it (move it aside to share)" >&2
    fi
  done
fi

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

# --- 3. copy the global CLAUDE.md into the yard ------------------------------
# The operator's global agent instructions, copied in once (not a mount, not symlinked) so
# the in-yard agent uses them without rewriting. Host path: HOST_CLAUDE_MD (config/host.env,
# no host-path literal here). Refreshed on each re-provision.
echo "CLAUDE.md:"
if [ -n "${HOST_CLAUDE_MD:-}" ] && [ -f "$HOST_CLAUDE_MD" ]; then
  incus file push "$HOST_CLAUDE_MD" \
    "$INSTANCE_NAME/home/$DEV_USER/.claude/CLAUDE.md" "${PROJ[@]}" \
    --create-dirs --uid "$DEV_UID" --gid "$DEV_UID" --mode 0644
  ok "copied $HOST_CLAUDE_MD -> ~$DEV_USER/.claude/CLAUDE.md"
else
  ok "no HOST_CLAUDE_MD file to copy — skipping (operator can add one and re-run)"
fi

# --- summary -----------------------------------------------------------------
echo
ok "Phase 3 done."
cat <<MSG

Verify:
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- systemctl --no-pager status ssh docker
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- docker compose version
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- id $DEV_USER          # groups: yard kvm docker
  incus exec $INSTANCE_NAME "${PROJ[@]}" -- ls -la /srv

Next:
  - Phase 4: dependency profile (e.g. android) — caches into /srv/cache (per profile).
  - Phase 7: VS Code / SSH proxy ports.
MSG
