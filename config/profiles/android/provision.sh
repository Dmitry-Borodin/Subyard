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
GRADLE_USER_HOME="${GRADLE_USER_HOME:-/srv/cache/gradle}"
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
install -d -o "$DEV_USER" -g "$DEV_USER" "$ANDROID_SDK_ROOT" "$GRADLE_USER_HOME"
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
chown -R "$DEV_USER:$DEV_USER" "$ANDROID_SDK_ROOT" "$GRADLE_USER_HOME" "$JDK_HOME" 2>/dev/null || true

# 6. System-wide env so any login shell / Gradle in the yard finds the in-yard toolchain (JAVA_HOME for
#    Gradle; ANDROID_HOME is AGP's SDK source when a project does NOT pin sdk.dir in local.properties).
cat > /etc/profile.d/subyard-android.sh <<EOF
# Subyard P1 — in-yard Android toolchain (written by config/profiles/android/provision.sh).
export JAVA_HOME="$JDK_HOME"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
export GRADLE_USER_HOME="$GRADLE_USER_HOME"
case ":\$PATH:" in
  *":\$JAVA_HOME/bin:"*) ;;
  *) PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH" ;;
esac
export PATH
EOF
chmod 0644 /etc/profile.d/subyard-android.sh

# 7. sdk.dir reconciliation for BIND-MOUNTED projects. AGP resolves the SDK as local.properties
#    `sdk.dir` > $ANDROID_HOME > $ANDROID_SDK_ROOT, and a sdk.dir that points at a MISSING directory is
#    a hard error (no fallback to ANDROID_HOME). A project bound from the host shares its
#    local.properties (gitignored, host-only), which pins sdk.dir to a HOST path absent in the yard. We
#    must not edit that shared file — instead make each such host path RESOLVE inside the yard by
#    symlinking it to the in-yard SDK. Path is DISCOVERED per project, never hardcoded; idempotent; a
#    real directory already at that path is left untouched.
shopt -s nullglob
for lp in /srv/workspaces/*/src/local.properties; do
  d="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' "$lp" | tail -n1)"; d="${d%$'\r'}"
  case "$d" in ""|"$ANDROID_SDK_ROOT") continue ;; esac
  if [ -L "$d" ]; then
    [ "$(readlink -f "$d" 2>/dev/null)" = "$(readlink -f "$ANDROID_SDK_ROOT")" ] && continue
  elif [ -e "$d" ]; then
    echo "android provision: '$d' exists and is not our symlink — leaving as-is" >&2; continue
  fi
  install -d "$(dirname "$d")"; ln -sfn "$ANDROID_SDK_ROOT" "$d"
  echo "android provision: sdk.dir reconciled  $d -> $ANDROID_SDK_ROOT  ($lp)"
done
shopt -u nullglob

echo "android provision OK: jdk=$("$JDK_HOME/bin/java" -version 2>&1 | head -1) sdk=$ANDROID_SDK_ROOT api=$ANDROID_API"
