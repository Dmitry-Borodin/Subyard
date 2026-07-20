#!/usr/bin/env bash
# keys.sh — host-side credential ledger tools, store and auto-sync timer stage.

[ -n "${SUBYARD_STAGE_KEYS_SOURCED:-}" ] && return 0
SUBYARD_STAGE_KEYS_SOURCED=1

stage_keys_check() {
  keys_initialized \
    && "$SCRIPT_DIR/install-key-tools.sh" --check >/dev/null 2>&1 \
    && "$SCRIPT_DIR/install-keys-auto-sync.sh" --check >/dev/null 2>&1
}
stage_keys_plan() {
  printf 'Initialize the host-side encrypted credential ledger + its persistent 6-hour sync timer\n'
}
stage_keys_apply() {
  "$SCRIPT_DIR/install-key-tools.sh" --yes
  keys_init_store
  "$SCRIPT_DIR/install-keys-auto-sync.sh" --yes
}
stage_keys_verify() { stage_keys_check; }
