#!/usr/bin/env bash
# config/profiles/openclaw/provision.sh — install the OpenClaw toolchain INTO THE YARD (L1) so an
# agent working directly in the yard can build the codebase and run e2e. P1 baseline (no per-agent
# container). Runs INSIDE the yard as root, piped by scripts/10-provision-profile.sh
# (`incus exec … -- bash -s`). Idempotent. Mirrors the project devcontainer (vasily-dev.Dockerfile);
# the project's Dockerfile stays the source of truth — versions arrive via --env from profile.conf.
#
# Validated live in the yard 2026-06-25 (Debian 13). Vars (with defaults): NODE_VERSION,
# COREPACK_VERSION, PNPM_VERSION, DEV_USER, OPTIONAL_FEATURES.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.22.2}"
COREPACK_VERSION="${COREPACK_VERSION:-0.31.0}"
PNPM_VERSION="${PNPM_VERSION:-11.2.2}"
DEV_USER="${DEV_USER:-dev}"
OPTIONAL_FEATURES="${OPTIONAL_FEATURES:-}"

export DEBIAN_FRONTEND=noninteractive

# 1. Node — pinned, from nodejs.org into /usr/local (shadows the distro node on PATH; distro stays).
if [ "$(/usr/local/bin/node --version 2>/dev/null)" != "v${NODE_VERSION}" ]; then
  case "$(dpkg --print-architecture)" in
    amd64) na=x64 ;; arm64) na=arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"; base="node-v${NODE_VERSION}-linux-${na}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${base}.tar.xz" -o "$tmp/${base}.tar.xz"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$tmp/sha.txt"
  ( cd "$tmp" && grep " ${base}.tar.xz\$" sha.txt | sha256sum -c - )
  tar -xJf "$tmp/${base}.tar.xz" -C /usr/local --strip-components=1
  rm -rf "$tmp"
fi

# 2. corepack + pnpm, with an arch-scoped pnpm shim so ad-hoc installs don't pull win/mac/musl
#    variants of OpenClaw's optional native deps.
/usr/local/bin/npm install -g "corepack@${COREPACK_VERSION}" >/dev/null
/usr/local/bin/corepack enable >/dev/null
/usr/local/bin/corepack prepare "pnpm@${PNPM_VERSION}" --activate >/dev/null
cat > /usr/local/bin/pnpm <<'SH'
#!/usr/bin/env bash
exec corepack pnpm \
  --config.supportedArchitectures.os=linux \
  --config.supportedArchitectures.cpu=current \
  --config.supportedArchitectures.libc=glibc "$@"
SH
chmod +x /usr/local/bin/pnpm

# 3. Python dev venv at /opt/venv (harness tools install here; package itself comes from src/).
[ -x /opt/venv/bin/python ] || python3 -m venv /opt/venv
/opt/venv/bin/pip install -q --upgrade pip setuptools wheel

# 4. Shared writable caches (agents fill them; no seeder). Point package managers here via env contract.
install -d -o "$DEV_USER" -g "$DEV_USER" /srv/cache/pnpm /srv/cache/pip /srv/cache/npm

# 5. OPTIONAL_FEATURES (off by default) — heavy capability for the full e2e matrix.
for feat in $OPTIONAL_FEATURES; do
  case "$feat" in
    browser_tests)
      # System chromium + libs baked once (binaries cache in /srv/cache/playwright at first run).
      apt-get update -qq
      apt-get install -y -qq chromium fonts-liberation fonts-noto-color-emoji \
        libnss3 libgbm1 libxss1 libasound2t64 2>/dev/null \
        || apt-get install -y -qq chromium fonts-liberation libnss3 libgbm1
      install -d -o "$DEV_USER" -g "$DEV_USER" /srv/cache/playwright
      ;;
    sandbox_tests)
      # Rootless Docker for the coding-sandbox (validated: --force needed since rootful coexists;
      # storage-driver overlayfs is native, fuse-overlayfs is fallback). DOCKER_HOST is NOT exported
      # globally — OpenClaw scopes it to the coding-sandbox build step.
      apt-get update -qq
      apt-get install -y -qq docker-ce-rootless-extras fuse-overlayfs slirp4netns \
        bubblewrap dbus-user-session uidmap
      loginctl enable-linger "$DEV_USER" >/dev/null 2>&1 || true
      runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$DEV_USER")" \
        dockerd-rootless-setuptool.sh install --force >/dev/null 2>&1 || true
      ;;
    *) echo "openclaw provision: unknown OPTIONAL_FEATURE '$feat' — skipping" >&2 ;;
  esac
done

echo "openclaw provision OK: node=$(/usr/local/bin/node --version) pnpm=$(/usr/local/bin/pnpm --version 2>/dev/null) venv=$([ -x /opt/venv/bin/python ] && echo yes)"
