#!/usr/bin/env bash
# config/profiles/openclaw/provision.sh — install the OpenClaw toolchain into the yard (run as root
# inside the yard by 10-provision-profile.sh; idempotent). Vars: NODE_VERSION, COREPACK_VERSION,
# PNPM_VERSION, DEV_USER, OPTIONAL_FEATURES.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.22.2}"
COREPACK_VERSION="${COREPACK_VERSION:-0.31.0}"
PNPM_VERSION="${PNPM_VERSION:-11.2.2}"
DEV_USER="${DEV_USER:-dev}"
OPTIONAL_FEATURES="${OPTIONAL_FEATURES:-}"

export DEBIAN_FRONTEND=noninteractive

# 1. Node — pinned, from nodejs.org into /usr/local (shadows the distro node).
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

# 2. corepack + pnpm; arch-scoped shim so ad-hoc installs don't pull win/mac/musl native variants.
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

# 3. Python dev venv.
[ -x /opt/venv/bin/python ] || python3 -m venv /opt/venv
/opt/venv/bin/pip install -q --upgrade pip setuptools wheel

# 4. Shared caches (agents fill them; package managers point here via profile.conf).
install -d -o "$DEV_USER" -g "$DEV_USER" /srv/cache/pnpm /srv/cache/pip /srv/cache/npm

# 5. OPTIONAL_FEATURES (off by default) — the heavy e2e capability.
for feat in $OPTIONAL_FEATURES; do
  case "$feat" in
    browser_tests)
      apt-get update -qq
      apt-get install -y -qq chromium fonts-liberation fonts-noto-color-emoji \
        libnss3 libgbm1 libxss1 libasound2t64 2>/dev/null \
        || apt-get install -y -qq chromium fonts-liberation libnss3 libgbm1
      install -d -o "$DEV_USER" -g "$DEV_USER" /srv/cache/playwright
      ;;
    sandbox_tests)
      # rootless docker — --force needed (rootful coexists); overlayfs is the native storage driver.
      apt-get update -qq
      apt-get install -y -qq docker-ce-rootless-extras fuse-overlayfs slirp4netns \
        bubblewrap dbus-user-session uidmap
      loginctl enable-linger "$DEV_USER" >/dev/null 2>&1 || true
      uid="$(id -u "$DEV_USER")"
      runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        dockerd-rootless-setuptool.sh install --force >/dev/null 2>&1 || true
      # setup flips dev's default context to rootless — restore default so shared rootful agent.sh works.
      runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        docker context use default >/dev/null 2>&1 || true
      ;;
    *) echo "openclaw provision: unknown OPTIONAL_FEATURE '$feat' — skipping" >&2 ;;
  esac
done

echo "openclaw provision OK: node=$(/usr/local/bin/node --version) pnpm=$(/usr/local/bin/pnpm --version 2>/dev/null) venv=$([ -x /opt/venv/bin/python ] && echo yes)"
