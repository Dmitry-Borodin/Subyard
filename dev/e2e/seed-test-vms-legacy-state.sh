#!/usr/bin/env bash
# Seed legacy L1 state in a disposable VM1 candidate yard.
set -euo pipefail

die() { printf 'legacy-test-vms-fixture: %s\n' "$*" >&2; exit 2; }

[ "${SUBYARD_E2E_VM:-}" = 1 ] \
  || die "run this fixture only through dev/agent-e2e.sh --vm 1"
[ "${SUBYARD_E2E_LEGACY_FIXTURE:-0}" = 1 ] \
  || die "set SUBYARD_E2E_LEGACY_FIXTURE=1 to confirm mutation of the disposable candidate"
[ "$#" -eq 2 ] || die "usage: seed-test-vms-legacy-state.sh INCUS_PROJECT INSTANCE"

project="$1"
instance="$2"
case "$project" in '' | *[!a-z0-9_-]*) die "project must be an explicit safe name" ;; esac
case "$instance" in '' | *[!a-z0-9_-]*) die "instance must be an explicit safe name" ;; esac
command -v incus >/dev/null 2>&1 || die "Incus is required in disposable VM1"
[ "$(incus config get "$instance" user.subyard.managed --project "$project" 2>/dev/null)" = true ] \
  || die "$project/$instance is not a Subyard-managed candidate"
[ "$(incus list "$instance" --project "$project" -f csv -c t 2>/dev/null)" = CONTAINER ] \
  || die "$project/$instance is not the candidate L1 container"

incus exec "$instance" --project "$project" -- bash -euo pipefail -s <<'LEGACY'
getent group incus-admin >/dev/null || groupadd --system incus-admin
getent group yard >/dev/null || groupadd --system yard
usermod -aG incus-admin,yard dev

state=/var/lib/subyard/test-vms
install -d -m 2770 -o root -g yard "$state"
chmod 2770 "$state"
find "$state" -mindepth 1 -maxdepth 1 -type f \
  -exec chown root:yard -- {} + -exec chmod 0660 -- {} +

systemctl disable --now subyard-test-vms-firewall.service >/dev/null 2>&1 || true
nft delete table inet subyard_e2e >/dev/null 2>&1 || true
rm -f /etc/systemd/system/subyard-test-vms-firewall.service \
  /usr/local/libexec/subyard/test-vms-firewall

agent_user=subyard-e2e-agent
agent_home=/var/lib/subyard/e2e-agent
if id -u "$agent_user" >/dev/null 2>&1; then
  pkill -KILL -u "$agent_user" >/dev/null 2>&1 || true
  userdel --remove "$agent_user" >/dev/null 2>&1 || true
fi
if [ -e "$agent_home" ]; then find "$agent_home" -depth -delete; fi
rm -f /etc/ssh/sshd_config.d/90-subyard-e2e-agent.conf

systemctl daemon-reload
sshd -t
systemctl reload ssh.service
LEGACY

printf '  [ok] seeded legacy nested-VM boundary in %s/%s\n' "$project" "$instance"
printf '       current init must remove legacy privileges and restore the boundary\n'
