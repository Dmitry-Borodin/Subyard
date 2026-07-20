#!/usr/bin/env bash
# git-identity.sh — in-yard Git identity and bind-worktree trust stage.

[ -n "${SUBYARD_STAGE_GIT_IDENTITY_SOURCED:-}" ] && return 0
SUBYARD_STAGE_GIT_IDENTITY_SOURCED=1

stage_git_identity_check() {
  reconcile_incus_reachable || return 1
  if reconcile_instance_running; then
    incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -s "/home/${DEV_USER:-dev}/.gitconfig" >/dev/null 2>&1
  else
    reconcile_power_stopped
  fi
}
stage_git_identity_plan() { printf 'Reconcile in-yard git config and bind-worktree trust\n'; }
stage_git_identity_apply() { "$SCRIPT_DIR/08-git-identity.sh" --yes; }
stage_git_identity_verify() { stage_git_identity_check; }
