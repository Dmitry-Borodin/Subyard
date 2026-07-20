#!/usr/bin/env bash
# extras.sh — aggregate project/profile-requested L1 devices and capabilities.

[ -n "${SUBYARD_STAGE_EXTRAS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_EXTRAS_SOURCED=1

stage_extras_check() { "$SCRIPT_DIR/09-yard-extras.sh" --check >/dev/null 2>&1; }
stage_extras_plan() { printf 'Apply yard extras requested by projects (mounts/caps/devices)\n'; }
stage_extras_apply() { "$SCRIPT_DIR/09-yard-extras.sh" --yes; }
stage_extras_verify() { stage_extras_check; }
