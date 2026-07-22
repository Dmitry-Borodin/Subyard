#!/usr/bin/env bash
# Every production shell file has an explicit physical boundary; new/unclassified shims fail CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'shell ownership: %s\n' "$*" >&2; exit 1; }

classify() {
  case "$1" in
    adapters/command.sh|adapters/yard-control.sh) printf 'system-adapter\n' ;;
    credentials/crypto.sh|credentials/domain.sh|credentials/materialize.sh|credentials/peers.sh|\
    credentials/policy.sh|credentials/revision-adapter.sh|credentials/store.sh|\
    credentials/sync-state.sh|credentials/sync.sh|credentials/transport.sh|credentials/verification.sh)
      printf 'credential-payload\n' ;;
    lib/cache.sh|lib/config.sh|lib/context.sh|lib/e2e-agent-enrollment.sh|lib/env.sh|\
    lib/host.sh|lib/project-snapshot.sh|\
    lib/registry.sh|lib/runtime.sh|lib/ssh-config.sh|lib/ui.sh)
      printf 'adapter-contract\n' ;;
    reconcile/facts.sh|reconcile/finalize.sh|reconcile/planner.sh|reconcile/registry.sh|\
    reconcile/stages/extras.sh|reconcile/stages/git-identity.sh|reconcile/stages/incus.sh|\
    reconcile/stages/instance.sh|reconcile/stages/keys.sh|reconcile/stages/mounts.sh|\
    reconcile/stages/network.sh|reconcile/stages/power-import.sh|reconcile/stages/power.sh|\
    reconcile/stages/project.sh|reconcile/stages/provision.sh|reconcile/stages/security.sh|\
    reconcile/stages/ssh.sh|reconcile/stages/test-vms.sh)
      printf 'safety-reconcile\n' ;;
    00-check-host.sh|01-install-incus.sh|02-create-project.sh|03-create-subyard.sh|\
    04-provision-subyard.sh|05-mount-host-paths.sh|06-network.sh|07-ssh-access.sh|\
    08-git-identity.sh|09-yard-extras.sh|10-provision-profile.sh|99-teardown.sh|\
    init.sh|install-key-tools.sh|install-keys-auto-sync.sh|install-power-reconciler.sh|\
    lib-power.sh|lib-resources.sh|lib-service.sh|power-state.sh|reconcile-test-vms.sh|\
    security-lint.sh|status-probe.sh|yard-boot-reconcile.sh|yard-ctl.sh|yard-info.sh|\
    yard-logs.sh|yard-usage.sh|yard-yards.sh)
      printf 'system-safety\n' ;;
    agent-configs.sh|project-clone.sh|project-code.sh|project-env.sh|project-export.sh|\
    project-remove.sh|project-sync.sh|provision-test-vms-inner.sh|sy-stage.sh|\
    vscode-remote-maintenance.sh|yard-authorize.sh|yard-shell.sh)
      printf 'profile-project-adapter\n' ;;
    state/metadata.sh|state/transport.sh|yard-remote.sh)
      printf 'metadata-transport\n' ;;
    yard-keys.sh)
      printf 'credential-payload\n' ;;
    test-vms-inner.sh|test-vms-status.sh|test-vms.sh|agent-e2e.sh)
      printf 'e2e-adapter\n' ;;
    build-engine.sh|install-cli.sh|install-engine-release.sh|install-runtime-release.sh|\
    package-engine.sh|update-engine.sh)
      printf 'release-delivery\n' ;;
    *) return 1 ;;
  esac
}

while IFS= read -r relative; do
  owner="$(classify "$relative")" || fail "unclassified production shell file: scripts/$relative"
  [ -n "$owner" ] || fail "empty owner for scripts/$relative"
done < <(find "$ROOT/scripts" -type f -name '*.sh' -printf '%P\n' | sort)

while IFS='|' read -r name _aliases handler _rest; do
  case "$name" in ''|'#'*) continue ;; esac
  case "$handler" in
    @*) continue ;;
    *.sh)
      [ -f "$ROOT/scripts/$handler" ] || fail "manifest handler is missing: scripts/$handler"
      classify "$handler" >/dev/null || fail "manifest handler has no physical owner: scripts/$handler" ;;
  esac
done < "$ROOT/config/commands.registry"

printf 'ok: every production shell file has an explicit physical ownership class\n'
