#!/usr/bin/env bash
# registry.sh — typed, ordered reconciliation stage registry.

[ -n "${SUBYARD_RECONCILE_REGISTRY_SOURCED:-}" ] && return 0
SUBYARD_RECONCILE_REGISTRY_SOURCED=1

RECONCILE_DIR="${RECONCILE_DIR:-$SCRIPT_DIR/reconcile}"

# Stage modules own the full check/plan/apply/verify contract. Source order is dependency order;
# execution order is the single registry below.
# shellcheck source=scripts/reconcile/facts.sh
. "$RECONCILE_DIR/facts.sh"
# shellcheck source=scripts/reconcile/stages/incus.sh
. "$RECONCILE_DIR/stages/incus.sh"
# shellcheck source=scripts/reconcile/stages/project.sh
. "$RECONCILE_DIR/stages/project.sh"
# shellcheck source=scripts/reconcile/stages/instance.sh
. "$RECONCILE_DIR/stages/instance.sh"
# shellcheck source=scripts/reconcile/stages/network.sh
. "$RECONCILE_DIR/stages/network.sh"
# shellcheck source=scripts/reconcile/stages/power-import.sh
. "$RECONCILE_DIR/stages/power-import.sh"
# shellcheck source=scripts/reconcile/stages/mounts.sh
. "$RECONCILE_DIR/stages/mounts.sh"
# shellcheck source=scripts/reconcile/stages/provision.sh
. "$RECONCILE_DIR/stages/provision.sh"
# shellcheck source=scripts/e2e-lab/stage.sh
. "$SCRIPT_DIR/e2e-lab/stage.sh"
# shellcheck source=scripts/reconcile/stages/ssh.sh
. "$RECONCILE_DIR/stages/ssh.sh"
# shellcheck source=scripts/reconcile/stages/git-identity.sh
. "$RECONCILE_DIR/stages/git-identity.sh"
# shellcheck source=scripts/reconcile/stages/extras.sh
. "$RECONCILE_DIR/stages/extras.sh"
# shellcheck source=scripts/reconcile/stages/power.sh
. "$RECONCILE_DIR/stages/power.sh"
# shellcheck source=scripts/reconcile/stages/keys.sh
. "$RECONCILE_DIR/stages/keys.sh"
# shellcheck source=scripts/reconcile/stages/security.sh
. "$RECONCILE_DIR/stages/security.sh"

# One descriptor per stage: id|function-prefix. Function names are derived, so a row cannot mix
# the check from one stage with the apply/verify from another as parallel arrays could.
RECONCILE_STAGES=(
  'incus|stage_incus'
  'project|stage_project'
  'network|stage_network'
  'power-import|stage_power_import'
  'instance|stage_instance'
  'mounts|stage_mounts'
  'provision|stage_provision'
  'test-vms|stage_test_vms'
  'ssh|stage_ssh'
  'git-identity|stage_git_identity'
  'extras|stage_extras'
  'power|stage_power'
  'keys|stage_keys'
  'security|stage_security'
)

reconcile_registry_validate() {
  local row id prefix suffix fn seen=' '
  [ "${#RECONCILE_STAGES[@]}" -gt 0 ] || die 'internal: reconciliation stage registry is empty'
  for row in "${RECONCILE_STAGES[@]}"; do
    IFS='|' read -r id prefix extra <<<"$row"
    [ -n "$id" ] && [ -n "$prefix" ] && [ -z "${extra:-}" ] \
      || die "internal: invalid reconciliation stage row '$row'"
    case "$id" in -* | *[!a-z0-9-]*) die "internal: invalid reconciliation stage id '$id'" ;; esac
    case " $seen " in *" $id "*) die "internal: duplicate reconciliation stage '$id'" ;; esac
    seen+="$id "
    for suffix in check plan apply verify; do
      fn="${prefix}_${suffix}"
      declare -F "$fn" >/dev/null || die "internal: reconciliation stage '$id' has no $suffix function ($fn)"
    done
  done
}

reconcile_stage_prefix() {
  local wanted="${1:?need stage id}" row id prefix
  for row in "${RECONCILE_STAGES[@]}"; do
    IFS='|' read -r id prefix <<<"$row"
    [ "$id" = "$wanted" ] && { printf '%s\n' "$prefix"; return 0; }
  done
  return 1
}

reconcile_stage_call() {
  local id="${1:?need stage id}" verb="${2:?need stage verb}" prefix fn
  case "$verb" in check | plan | apply | verify) ;; *) die "internal: invalid stage verb '$verb'" ;; esac
  prefix="$(reconcile_stage_prefix "$id")" || die "internal: unknown reconciliation stage '$id'"
  fn="${prefix}_${verb}"
  "$fn"
}
