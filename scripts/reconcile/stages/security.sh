#!/usr/bin/env bash
# security.sh — static and live host-boundary security invariant stage.

[ -n "${SUBYARD_STAGE_SECURITY_SOURCED:-}" ] && return 0
SUBYARD_STAGE_SECURITY_SOURCED=1

stage_security_check() { "$SCRIPT_DIR/security-lint.sh" --quiet --require-live >/dev/null 2>&1; }
stage_security_plan() { printf 'Validate static and live host-boundary security invariants\n'; }
stage_security_apply() { "$SCRIPT_DIR/security-lint.sh" --require-live; }
stage_security_verify() { stage_security_check; }
