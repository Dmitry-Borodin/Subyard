#!/usr/bin/env bash
# emulator-run.sh — launch an AVD with hardware GLES, headless, inside the yard (run as dev).
#
# -gpu host renders GLES via GLX (needs an X display), but the passed-through GPU render node only does
# HW GL via EGL. Bridge: a headless wlroots compositor (cage) on the render node exposes Xwayland, giving
# the emulator a HW-accelerated X display — in-distro (cage + xwayland), render node only (no card node,
# no external VirtualGL). Deps come from provision.sh. Reads EMULATOR_* from the android profile.conf.
#
# Usage: emulator-run.sh [avd-name] [extra emulator args...]
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# profile.conf = emulator-launch contract (EMULATOR_GPU/FLAGS, ANDROID_API); profile.d = live toolchain env.
# shellcheck source=/dev/null
[ -r "$HERE/profile.conf" ] && { set -a; . "$HERE/profile.conf"; set +a; }
# shellcheck source=/dev/null
[ -r /etc/profile.d/subyard-android.sh ] && { set -a; . /etc/profile.d/subyard-android.sh; set +a; }
: "${ANDROID_HOME:?ANDROID_HOME unset — run 'yard provision android' first}"

AVD="${1:-${EMULATOR_AVD:-yardtest}}"; [ $# -gt 0 ] && shift
ANDROID_API="${ANDROID_API:-36}"
SYSTEM_IMAGE="${SYSTEM_IMAGE:-system-images;android-${ANDROID_API};google_apis;x86_64}"
EMULATOR_GPU="${EMULATOR_GPU:-host}"
# shellcheck disable=SC2206
EMULATOR_FLAGS=(${EMULATOR_FLAGS:--no-audio -no-snapshot -no-boot-anim})
EMULATOR_DEVICE="${EMULATOR_DEVICE:-pixel}"   # real phone profile; avdmanager default is a tiny 320x640 screen

command -v cage >/dev/null || { echo "emulator-run: 'cage' missing — provision the android profile" >&2; exit 1; }

# Pick a GPU render node (renderD128 isn't universal). Fail loudly if none — -gpu host needs it.
RNODE=""; for n in /dev/dri/renderD*; do [ -e "$n" ] && { RNODE="$n"; break; }; done
[ -n "$RNODE" ] || { echo "emulator-run: no /dev/dri/renderD* — GPU not passed through; -gpu $EMULATOR_GPU needs it" >&2; exit 1; }

# Create the AVD on first use.
if ! "$ANDROID_HOME"/emulator/emulator -list-avds 2>/dev/null | grep -qx "$AVD"; then
  echo "emulator-run: creating AVD '$AVD' ($EMULATOR_DEVICE) from $SYSTEM_IMAGE"
  echo no | "$ANDROID_HOME"/cmdline-tools/latest/bin/avdmanager create avd -n "$AVD" -k "$SYSTEM_IMAGE" --device "$EMULATOR_DEVICE" --force >/dev/null
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless
export WLR_RENDERER_ALLOW_SOFTWARE=0   # fail rather than silently fall back to software GL (the CPU trap)
export WLR_RENDER_DRM_DEVICE="$RNODE"
unset DISPLAY                          # cage's Xwayland owns DISPLAY

echo "emulator-run: '$AVD' -gpu $EMULATOR_GPU on $RNODE (headless cage + Xwayland)"
exec cage -- "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -gpu "$EMULATOR_GPU" "${EMULATOR_FLAGS[@]}" "$@"
