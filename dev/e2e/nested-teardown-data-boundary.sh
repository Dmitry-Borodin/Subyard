#!/usr/bin/env bash
# Real outer+nested teardown boundary acceptance. Run only on a disposable leased VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE=''
OUTER_YARD=''
OUTER_PROJECT=''
OUTER_INSTANCE=''
OUTER_POOL=''

die() { printf 'nested-teardown-boundary: %s\n' "$*" >&2; exit 2; }

[ -n "${SUBYARD_E2E_VM:-}" ] || die 'run through dev/agent-e2e.sh'
for command in go incus jq sudo timeout; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done
COMMAND_TIMEOUT="${NESTED_TEARDOWN_COMMAND_TIMEOUT:-1800}"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die 'qemu-system-x86_64 or apt-get is required'
  printf '  [ .. ] installing QEMU for the outer VM fixture\n'
  sudo -n apt-get update >/dev/null
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-system-x86 >/dev/null
fi

if [ ! -x "$ROOT/.build/yard" ]; then
  "$ROOT/dev/build-engine.sh"
fi

yard() {
  timeout --foreground "$COMMAND_TIMEOUT" "$ROOT/.build/yard" -Y "$OUTER_YARD" "$@"
}

setting() {
  local key="$1" value
  value="$(yard config show "$key" | sed -n 's/^effective: //p')"
  [ -n "$value" ] || die "could not resolve $key"
  printf '%s\n' "$value"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$OUTER_PROJECT" ] && incus project show "$OUTER_PROJECT" >/dev/null 2>&1; then
    yard teardown --yes >/dev/null 2>&1 || rc=3
  fi
  if [ -n "$OUTER_POOL" ] && incus storage show "$OUTER_POOL" --project default >/dev/null 2>&1 \
    && [ "$(incus storage get "$OUTER_POOL" user.subyard.owner --project default 2>/dev/null)" = \
      nested-teardown-e2e-v1 ]; then
    incus storage delete "$OUTER_POOL" --project default >/dev/null 2>&1 || rc=3
  fi
  if [ -n "$STATE" ] && [[ "$STATE" = /var/tmp/subyard-nested-teardown.* ]] \
    && [ -f "$STATE/.marker" ] && [ "$(<"$STATE/.marker")" = nested-teardown-e2e-v1 ]; then
    sudo -n find "$STATE" -depth -delete || rc=3
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

STATE="$(mktemp -d /var/tmp/subyard-nested-teardown.XXXXXX)"
printf '%s\n' nested-teardown-e2e-v1 > "$STATE/.marker"
token="$(printf '%s' "${STATE##*.}" | tr '[:upper:]' '[:lower:]')"
OUTER_YARD="nested-e2e-$token"
OUTER_PROJECT="subyard-$OUTER_YARD"
OUTER_INSTANCE="yard-$OUTER_YARD"
OUTER_POOL="nested-e2e-$token"
outer_bridge="ne${token:0:8}br0"

incus project show "$OUTER_PROJECT" >/dev/null 2>&1 \
  && die "refusing existing project $OUTER_PROJECT"
incus storage show "$OUTER_POOL" --project default >/dev/null 2>&1 \
  && die "refusing existing pool $OUTER_POOL"
incus storage create "$OUTER_POOL" dir --project default >/dev/null
incus storage set "$OUTER_POOL" user.subyard.owner=nested-teardown-e2e-v1 \
  --project default >/dev/null

export SUBYARD_OPERATOR_HOME="$STATE/operator"
export SUBYARD_CONFIG_HOME="$STATE/config"
export SUBYARD_HOME="$STATE/data"
export STORAGE_PATH="$STATE/storage"
export SUBYARD_NO_AUDIT=1
export SUBYARD_KEYS_SYSTEMD_SKIP_ENABLE=1
export MIN_DISK_GIB=1
export REC_DISK_GIB=1
export HOST_CLAUDE_MD=
export HOST_CODEX_AGENTS_MD=
export HOST_OPENCODE_AGENTS_MD=
install -d -m 0700 "$SUBYARD_OPERATOR_HOME" "$SUBYARD_CONFIG_HOME/yards/$OUTER_YARD"

ssh_port=$((32000 + ($$ % 10000)))
while ss -H -ltn "sport = :$ssh_port" 2>/dev/null | grep -q .; do
  ssh_port=$((ssh_port + 1))
done
cat > "$SUBYARD_CONFIG_HOME/yards/$OUTER_YARD/config.env" <<EOF
SSH_PORT=$ssh_port
AGENTS=
INSTANCE_TYPE=vm
LIMITS_CPU=4
LIMITS_MEMORY=3GiB
SRV_POOL=$OUTER_POOL
INCUS_BRIDGE=$outer_bridge
HOST_MOUNTS=
HOST_LINKS=
HOST_BASE=$STATE/host
RESTRICTED_DISK_PATHS=$STATE/host
FORWARD_SSH_AGENT=0
DEV_SUDO=1
NESTED_E2E_VMS=0
EOF

printf '  [ .. ] creating the outer yard\n'
yard init --yes
yard start --yes
[ "$(incus config get "$OUTER_INSTANCE" user.subyard.managed --project "$OUTER_PROJECT")" = true ] \
  || die 'outer instance is not marker-owned'

printf '  [ .. ] syncing the exact candidate into the outer yard\n'
yard sync "$ROOT" --name NestedBoundary --target yard --yes >/dev/null
project_state="$(find "$SUBYARD_CONFIG_HOME/yards/$OUTER_YARD/projects" \
  -maxdepth 1 -type f -name '*.json' -print -quit)"
[ -n "$project_state" ] || die 'controller project state is missing'
project_id="$(jq -r '.projectId' "$project_state")"
outer_source="/srv/workspaces/$project_id/src"

yard code "$project_id" --yes > "$STATE/code.out"
outer_ssh="$(setting SSH_HOST)"
descriptor="$SUBYARD_CONFIG_HOME/workspaces/$outer_ssh-$project_id.code-workspace"
[ -f "$descriptor" ] || die 'controller-local workspace descriptor is missing'
jq -e --arg uri "vscode-remote://ssh-remote+$outer_ssh$outer_source" \
  '.folders == [{name:"NestedBoundary", uri:$uri}]' "$descriptor" >/dev/null \
  || die 'workspace descriptor does not contain the remote folder URI'

outer_dev() {
  timeout --foreground "$COMMAND_TIMEOUT" incus exec "$OUTER_INSTANCE" --project "$OUTER_PROJECT" \
    --user 1000 --group 1000 --env HOME=/home/dev --env USER=dev --env LOGNAME=dev -- "$@"
}

printf '  [ .. ] creating and tearing down a source inner yard\n'
outer_dev sh -euc '
  source=$1
  install -d "$HOME/.subyard/workspaces"
  printf "outer sentinel\n" > "$HOME/.subyard/workspaces/active.code-workspace"
  cd "$source"
  env \
    AGENTS= HOST_MOUNTS= HOST_LINKS= FORWARD_SSH_AGENT=0 DEV_SUDO=0 \
    NESTED_E2E_VMS=0 SSH_PORT=23222 MIN_DISK_GIB=1 REC_DISK_GIB=1 \
    SUBYARD_NO_AUDIT=1 SUBYARD_KEYS_SYSTEMD_SKIP_ENABLE=1 \
    HOST_CLAUDE_MD= HOST_CODEX_AGENTS_MD= HOST_OPENCODE_AGENTS_MD= \
    ./bin/yard init --yes
  sudo -n incus project show subyard >/dev/null
  env SUBYARD_NO_AUDIT=1 ./bin/yard teardown --yes
  ! sudo -n incus project show subyard >/dev/null 2>&1
  [ -f "$HOME/.subyard/workspaces/active.code-workspace" ]
  [ ! -e "$HOME/.config/subyard/projects" ]
  env SUBYARD_NO_AUDIT=1 ./bin/yard teardown --yes >/dev/null
' _ "$outer_source"

incus info "$OUTER_INSTANCE" --project "$OUTER_PROJECT" >/dev/null \
  || die 'inner teardown removed the outer instance'
[ -f "$descriptor" ] || die 'inner teardown removed the controller descriptor'
outer_dev sudo -n rm -rf -- /home/dev/.subyard
[ -f "$descriptor" ] || die 'agent data deletion removed the controller descriptor'
incus info "$OUTER_INSTANCE" --project "$OUTER_PROJECT" >/dev/null \
  || die 'agent data deletion stopped the outer instance'
yard shell "$project_id" --yes -- true \
  || die 'inner teardown or agent data deletion broke outer SSH transport'

printf 'ok: nested teardown preserves the outer yard, transport descriptor and foreign data\n'
