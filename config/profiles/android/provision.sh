#!/usr/bin/env bash
# config/profiles/android/provision.sh — install the Android toolchain INTO THE YARD (L1) so an agent
# working directly in the yard can build Android and run one emulator. P1 baseline (no per-agent
# container, no emulator pool — that is P2). Runs INSIDE the yard as root, piped by
# scripts/10-provision-profile.sh (`incus exec … -- bash -s`). Idempotent. HEAVY (tens of GiB) — gated
# behind an explicit provision, never automatic.
#
# Validated live in the yard 2026-06-25 against the CloudbasePredictor project (Gradle 9.4.1 / AGP 9.2.1
# / Kotlin 2.3.10 / sdk 36 / minSdk 25 / JDK17). Vars (with defaults): ANDROID_API, JDK_VERSION,
# BUILD_TOOLS_VERSION, SYSTEM_IMAGE, ANDROID_SDK_ROOT, CMDLINE_TOOLS_URL, DEV_USER.
set -euo pipefail

ANDROID_API="${ANDROID_API:-36}"
JDK_VERSION="${JDK_VERSION:-17}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.0.0}"
SYSTEM_IMAGE="${SYSTEM_IMAGE:-system-images;android-${ANDROID_API};google_apis;x86_64}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/srv/cache/android-sdk}"
DEV_USER="${DEV_USER:-dev}"
JDK_HOME="/opt/jdk-${JDK_VERSION}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip

# 1. JDK — Debian 13 ships only openjdk-21/25, NOT 17. Install Temurin from Adoptium (latest GA of the
#    requested major; api.adoptium.net redirects to the current binary, so no version pinning needed).
if [ ! -x "$JDK_HOME/bin/java" ]; then
  rm -rf "$JDK_HOME"; mkdir -p "$JDK_HOME"
  curl -fsSL -o /tmp/jdk.tgz \
    "https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/x64/jdk/hotspot/normal/eclipse"
  tar -xzf /tmp/jdk.tgz -C "$JDK_HOME" --strip-components=1; rm -f /tmp/jdk.tgz
fi
export JAVA_HOME="$JDK_HOME" PATH="$JDK_HOME/bin:$PATH"

# 2. Shared writable SDK + gradle caches (owner dev).
install -d -o "$DEV_USER" -g "$DEV_USER" "$ANDROID_SDK_ROOT" /srv/cache/gradle
export ANDROID_HOME="$ANDROID_SDK_ROOT" ANDROID_SDK_ROOT

# 3. cmdline-tools (sdkmanager bootstrap). URL: pinned via CMDLINE_TOOLS_URL, else current from Google's
#    repository manifest (numeric-sorted so we get the newest, not a lexical fluke).
if [ ! -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  url="${CMDLINE_TOOLS_URL:-}"
  if [ -z "$url" ]; then
    rev="$(curl -fsSL https://dl.google.com/android/repository/repository2-3.xml \
      | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | sort -t- -k3 -n | tail -1)"
    url="https://dl.google.com/android/repository/${rev}"
  fi
  tmp="$(mktemp -d)"; curl -fsSL -o "$tmp/clt.zip" "$url"
  unzip -q "$tmp/clt.zip" -d "$tmp/x"
  install -d "$ANDROID_SDK_ROOT/cmdline-tools"
  mv "$tmp/x/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"; rm -rf "$tmp"
fi
SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

# 4. Accept licenses + install components (idempotent — sdkmanager skips what's present).
yes 2>/dev/null | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" "platform-tools" "platforms;android-${ANDROID_API}" \
  "build-tools;${BUILD_TOOLS_VERSION}" "emulator" "$SYSTEM_IMAGE" >/dev/null

# 5. Ownership (sdkmanager may write as root) so dev can use the shared SDK.
chown -R "$DEV_USER:$DEV_USER" "$ANDROID_SDK_ROOT" /srv/cache/gradle "$JDK_HOME" 2>/dev/null || true

echo "android provision OK: jdk=$("$JDK_HOME/bin/java" -version 2>&1 | head -1) sdk=$ANDROID_SDK_ROOT api=$ANDROID_API"
