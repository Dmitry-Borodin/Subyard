#!/usr/bin/env bash
# init.sh — one-shot yard bring-up (`yard init`).
#
# Runs the whole pipeline end-to-end and idempotently: host preflight → install
# Incus → project → instance → network → mounts → provision → ssh → git identity
# → project extras. A re-run reconciles drift and skips finished steps; it is
# conservative and may miss a content-only change (`--configs` refreshes agent dotfiles;
# `--reset` remains the full destructive re-apply).
#
# Installing Incus moves you into the 'incus-admin' group, which only takes effect
# in a fresh session. Rather than stop and make you re-run, init re-execs itself
# under a fresh group session ('sg') so a single 'yard init' completes start to end.
#
# Usage: yard init [--configs | --reset] [-y]
#   yard init --configs   Refresh global agent instructions and default configs only; no rebuild.
#   yard init --reset     Tear down the yard, then a fresh init — force-apply a config change
#                         the conservative reconcile didn't pick up. Asks before anything.
#   -y, --yes             Skip the confirmation prompt (automation/CI).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")   # preserved so we can re-exec ourselves under a fresh group session
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=scripts/credentials/store.sh
. "$SCRIPT_DIR/credentials/store.sh"
# shellcheck source=scripts/credentials/crypto.sh
. "$SCRIPT_DIR/credentials/crypto.sh"
# shellcheck source=scripts/credentials/domain.sh
. "$SCRIPT_DIR/credentials/domain.sh"
# shellcheck source=scripts/credentials/revision-adapter.sh
. "$SCRIPT_DIR/credentials/revision-adapter.sh"
# shellcheck source=scripts/credentials/policy.sh
. "$SCRIPT_DIR/credentials/policy.sh"
# shellcheck source=scripts/credentials/sync-state.sh
. "$SCRIPT_DIR/credentials/sync-state.sh"
# shellcheck source=scripts/credentials/transport.sh
. "$SCRIPT_DIR/credentials/transport.sh"
# shellcheck source=scripts/credentials/materialize.sh
. "$SCRIPT_DIR/credentials/materialize.sh"
# shellcheck source=scripts/credentials/verification.sh
. "$SCRIPT_DIR/credentials/verification.sh"
# shellcheck source=scripts/credentials/peers.sh
. "$SCRIPT_DIR/credentials/peers.sh"
# shellcheck source=scripts/credentials/sync.sh
. "$SCRIPT_DIR/credentials/sync.sh"

# ============================================================================
# Reconciliation context and explicit stage composition.
# ============================================================================
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
INCUS_BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
STORAGE_POOL="${STORAGE_POOL:-default}"
PROJ=(--project "$INCUS_PROJECT")
MIN_INCUS_VER="${MIN_INCUS_VER:-6.0.6}"

# shellcheck source=scripts/reconcile/registry.sh
. "$SCRIPT_DIR/reconcile/registry.sh"
# shellcheck source=scripts/reconcile/planner.sh
. "$SCRIPT_DIR/reconcile/planner.sh"

# ============================================================================
# Interactive prompts — asked only after the main 'Proceed?' gate.
# ============================================================================

# want_zabbly <install|upgrade> — pull Incus from the Zabbly LTS-6.0 repo? It is the only
# source that meets the nested-Docker floor, so the default is YES; -y / a non-TTY take
# that default automatically. Returns non-zero only on an explicit "no" (or when apt is
# absent, since Zabbly is apt-only and there is nothing to add).
want_zabbly() {
  command -v apt-get >/dev/null 2>&1 || return 1
  { [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; } && return 0
  local ans
  read -r -p "  Add the Zabbly LTS-6.0 apt repo and ${1:-install} Incus (>= $MIN_INCUS_VER) from there? [Y/n] " ans
  case "$ans" in [nN] | [nN][oO]) return 1 ;; *) return 0 ;; esac
}

# Opt-in toolchain provisioning at the end of init — default N, never under -y / non-TTY (heavy).
offer_provision() {
  local profs hint; profs="$(stage_provision_profiles | paste -sd' ' -)"; hint="$(yard_cmd_hint)"
  if [ -n "$profs" ] && [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    local ans
    read -r -p "  Provision toolchains for [$profs] into the yard now? (heavy) [y/N] " ans
    case "$ans" in
      [yY] | [yY][eE][sS]) "$SCRIPT_DIR/10-provision-profile.sh" --yes ;;
      *) info "skipped — run later:  $hint provision" ;;
    esac
  elif [ -n "$profs" ]; then
    printf '  %s provision    # install the in-yard toolchain for: %s (heavy, explicit)\n' "$hint" "$profs"
  else
    printf '  %s provision -l # list profiles whose toolchain you can install into the yard\n' "$hint"
  fi
}

# ============================================================================
# Group-session re-exec.
# ============================================================================
# Installing Incus adds you to 'incus-admin', but the group only applies in a fresh session.
# Re-exec the whole init under a fresh group session ('sg') so one run completes. Guarded against looping; returns
# non-zero so callers fall back to the manual hint if 'sg' is missing or still can't
# connect. $1=1 → assume-yes in the child (the plan was already confirmed up top); the
# parent's Zabbly answer is carried in SUBYARD_ZABBLY so the unattended child honors an
# explicit "no" instead of silently re-deciding "yes" under assume-yes.
reexec_under_group() {
  [ "${SUBYARD_SG_REEXEC:-0}" = 1 ] && return 1
  command -v sg >/dev/null 2>&1 || return 1
  local q; printf -v q '%q ' "$SCRIPT_DIR/init.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  local pre="SUBYARD_SG_REEXEC=1"
  if [ "${1:-0}" = 1 ]; then
    pre+=" ASSUME_YES=1"
    if [ "${ZB+set}" = set ] && [ "${#ZB[@]}" -gt 0 ]; then pre+=" SUBYARD_ZABBLY=1"; else pre+=" SUBYARD_ZABBLY=0"; fi
  fi
  info "continuing under a fresh 'incus-admin' group session (no manual re-run needed)…"
  exec sg incus-admin -c "$pre exec $q"
}

# ============================================================================
# Steps — the actual bring-up, run only after confirmation.
# ============================================================================

# Read-only host preflight (00). Hard failures abort before anything mutates.
# SUBYARD_PREFLIGHT_STRICT=1 makes a cross-yard SSH_PORT collision a HARD failure here (init
# must not create a second yard on a port another yard already claims); a plain `yard check`
# leaves that check advisory (warn only).
host_preflight() {
  local base_present=0
  stage_instance_exists && base_present=1
  SUBYARD_PREFLIGHT_STRICT=1 SUBYARD_PREFLIGHT_BASE_PRESENT="$base_present" \
    "$SCRIPT_DIR/00-check-host.sh" \
    || die "host preflight failed — fix the items above, then re-run '$(yard_cmd_hint) init'"
}

# Install Incus on first run (then continue under a fresh group session), or upgrade it
# in place when it is older than the floor. ZB carries the --zabbly choice from main.
incus_install_or_upgrade() {
  if ! stage_incus_initialized; then
    info "→ install / init Incus"
    "$SCRIPT_DIR/01-install-incus.sh" --yes ${ZB[@]+"${ZB[@]}"}
    if ! reconcile_incus_reachable; then
      echo
      ok "Incus installed and you're added to 'incus-admin'."
      reexec_under_group 1 || true
      cat <<'MSG'

One step needs a fresh group session. Continue with:
    sg incus-admin -c 'yard init'
  (or re-login / run 'newgrp incus-admin', then: yard init)
MSG
      exit 0
    fi
  elif stage_incus_too_old; then
    info "→ upgrade Incus (>= $MIN_INCUS_VER)"
    "$SCRIPT_DIR/01-install-incus.sh" --yes ${ZB[@]+"${ZB[@]}"} --upgrade-only \
      || die "incus upgrade failed"
  fi
}

# ============================================================================
# --configs / --reset special modes.
# ============================================================================
maybe_configs() {
  local a configs=0 reset=0
  for a in "$@"; do
    [ "$a" = --configs ] && configs=1
    [ "$a" = --reset ] && reset=1
  done
  [ "$configs" = 1 ] || return 0
  [ "$reset" = 0 ] || die "--configs and --reset cannot be used together"
  exec "$SCRIPT_DIR/agent-configs.sh" "$@"
}

maybe_reset() {
  local a reset=0
  for a in "$@"; do [ "$a" = --reset ] && reset=1; done
  [ "$reset" = 1 ] || return 0
  announce "yard init --reset — full rebuild" \
    "Tear down the yard: DELETE the instance and its disk data (rootfs + /srv), then re-init from current config." \
    "Host-side sessions under \$HOST_BASE/host-agent-sessions persist; per-yard agent creds are lost (you re-login)." \
    "Use this when a normal 'yard init' didn't pick up a config change."
  proceed_or_die
  info "→ teardown"; "$SCRIPT_DIR/99-teardown.sh" --yes || die "teardown failed"
  info "→ rebuild (fresh init)"; exec env ASSUME_YES=1 "$SCRIPT_DIR/init.sh"
}

# ============================================================================
# Main.
# ============================================================================
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

maybe_configs "$@"
maybe_reset "$@"

# Incus installed + daemon unreachable + you're already in 'incus-admin' means this shell
# predates the group. Don't show a misleading all-[do] plan — continue in a fresh
# group session (nothing to reinstall; it's all already there).
if stage_incus_present && ! incus info >/dev/null 2>&1 && stage_incus_in_admin_db; then
  warn "Incus is installed and you're in 'incus-admin', but this shell session predates that group."
  reexec_under_group 0 || true
  cat <<'MSG'

Nothing to reinstall — continue in a fresh group session:
    sg incus-admin -c 'yard init'
  (or re-login / run 'newgrp incus-admin', then: yard init)
MSG
  exit 0
fi

# 1. Describe the plan (read-only). Nothing here mutates the host.
reconcile_print_plan
if [ "$RECONCILE_PENDING" = 0 ]; then
  ok "Everything is already set up — nothing to do."
  offer_provision   # a ready yard may still have an un-provisioned profile
  exit 0
fi

# 2. Read-only host preflight, now that we know there is work to do.
host_preflight

# 3. One confirmation covers the whole run: if Incus isn't set up yet, installing it
#    switches your group and init then continues UNATTENDED in a fresh session.
if ! stage_incus_initialized; then
  printf '%sNote:%s installing Incus adds you to '\''incus-admin'\''; init then continues\n' "$C_HEAD" "$C_OFF"
  printf '      in a fresh group session and runs the remaining steps without asking\n'
  printf '      again — this one confirmation covers them all.\n\n'
fi
proceed_or_die

# 4. Pick the Incus source — only when the distro package can't meet the floor.
#    Default YES to Zabbly; asked here, AFTER the main gate, never before it. A
#    group-session re-exec inherits the answer via SUBYARD_ZABBLY (set/0/1), so the
#    child never re-asks nor overrides an explicit "no" from the parent run.
ZB=()
if [ -n "${SUBYARD_ZABBLY:-}" ]; then
  [ "$SUBYARD_ZABBLY" = 1 ] && ZB=(--zabbly)
elif stage_incus_too_old; then
  want_zabbly upgrade && ZB=(--zabbly)
elif ! stage_incus_present && stage_incus_distro_too_old; then
  want_zabbly install && ZB=(--zabbly)
fi

# 5. Do it. Profile provisioning, when accepted interactively, runs while a fresh named yard is
#    temporarily up. Finalization then restores its default desired=stopped state.
reconcile_run_stages
offer_provision
reconcile_run_finalization

echo
_desired="$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
if [ "$_desired" = running ]; then
  ok "Subyard is up (desired=running; restored after host reboot)."
else
  ok "Subyard is configured and stopped (desired=stopped; named yards are off by default)."
fi
# Context-aware next steps: the default yard shows plain `yard …`; a named yard carries -Y so
# the copy-pasted commands target the same yard.
_hint="$(yard_cmd_hint)"
cat <<MSG

Next:
  $_hint status
  $([ "$_desired" = stopped ] && printf '%s start        # explicitly enable this named yard\n  ' "$_hint")$_hint sync .       # copy a code project into the yard (or: bind . to mount it)
  $_hint code .       # open it in VS Code (Remote-SSH into the yard)
MSG
