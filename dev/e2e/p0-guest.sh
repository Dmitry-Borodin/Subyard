#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TOKEN="${2:-}"
PEER_IP="${3:-}"
PEER_ROOT="/tmp/subyard-p0-peer-$TOKEN"
MARKER="subyard-p0-$TOKEN"

die() { printf 'p0-guest: %s\n' "$*" >&2; exit 2; }
valid_token() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_ip() { [[ "$1" =~ ^[0-9a-fA-F:.]+$ ]]; }
valid_token "$TOKEN" || die 'allocation token must be numeric'
[ -n "${SUBYARD_E2E_VM:-}" ] || die 'run through dev/agent-e2e.sh'

clean_tree() { # guarded path marker
  local path="$1" marker="$2"
  case "$path" in /tmp/subyard-p0-*) ;; *) die "unsafe cleanup path $path" ;; esac
  [ ! -e "$path" ] || [ "$(cat "$path/.subyard-p0-marker" 2>/dev/null)" = "$marker" ] \
    || die "refusing to clean unmarked path $path"
  [ ! -e "$path" ] || find "$path" -depth -delete
}

owner_project_contract() {
  local source="/tmp/subyard-p0-project-$TOKEN" patch
  clean_tree "$source" "$MARKER"
  install -d -m 0700 "$source"
  printf '%s\n' "$MARKER" > "$source/.subyard-p0-marker"
  printf 'base\n' > "$source/result.txt"
  ./bin/yard -Y e2e-yard sync "$source" --yes >/dev/null
  ./bin/yard -Y e2e-yard shell "$source" -- sh -c 'printf "mutated\n" >> result.txt'
  ./bin/yard -Y e2e-yard export "$source" >/dev/null
  patch="$(grep -RIl -- 'mutated' "${SUBYARD_HOME:-$HOME/.subyard}/exports" | head -n1)"
  [ -n "$patch" ] || die 'project export did not contain the guest change'
  ./bin/yard -Y e2e-yard remove "$source" --yes >/dev/null
  find "$patch" -delete
  clean_tree "$source" "$MARKER"
}

owner() {
  [ "$SUBYARD_E2E_VM" = 1 ] || die 'owner lane requires VM1'
  install -d -m 0700 private/yards
  printf 'YARD_TEMPLATE=e2e-vms\nSSH_PORT=2223\n' > private/yards/e2e-yard.env
  ./bin/yard -Y e2e-yard init --yes
  ./bin/yard -Y e2e-yard start
  SUBYARD_E2E_LEGACY_FIXTURE=1 \
    bash dev/e2e/seed-test-vms-legacy-state.sh subyard-e2e-yard yard-e2e-yard
  ./bin/yard -Y e2e-yard init --yes
  ./bin/yard -Y e2e-yard check
  ./bin/yard -Y e2e-yard init --yes
  [ "$(incus exec yard-e2e-yard --project subyard-e2e-yard -- stat -c '%U:%G:%a' /var/lib/subyard/test-vms)" = root:root:700 ] \
    || die 'nested state permissions did not converge'
  ! incus exec yard-e2e-yard --project subyard-e2e-yard -- id -nG dev | tr ' ' '\n' \
    | grep -Eq '^(incus-admin|yard)$' || die 'dev retained a privileged L1 group'
  owner_project_contract
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard --version >/dev/null
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard -Y e2e-yard list >/dev/null
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard -Y e2e-yard status >/dev/null
  bash dev/e2e/p0-real-incus.sh
  bash tests/engine-release.sh
  ./bin/yard -Y e2e-yard teardown --yes
  ! incus project show subyard-e2e-yard >/dev/null 2>&1 || die 'candidate project remains after teardown'
  printf 'ok: VM1 owner, legacy upgrade, lifecycle, Incus and rollback\n'
}

controller() (
  local temp
  [ "$SUBYARD_E2E_VM" = 2 ] || die 'controller lane requires VM2'
  shellcheck -x -S warning dev/e2e/p0-acceptance.sh dev/e2e/p0-guest.sh \
    dev/e2e/p0-real-incus.sh scripts/build-engine.sh tests/build-engine.sh \
    tests/agent-e2e.sh tests/real-host/incus-contract.sh
  ./tests/run.sh
  bash tests/real-host/ssh-rpc.sh
  temp="$(mktemp -d /tmp/subyard-p0-tools.XXXXXX)"
  trap 'find "$temp" -depth -delete' EXIT
  SUBYARD_HOME="$temp/state" SUBYARD_KEYS_TOOLS_DIR="$temp/tools" \
    bash scripts/install-key-tools.sh -y >/dev/null
  SUBYARD_REAL_KEYS_TOOLS_DIR="$temp/tools" bash tests/real-host/credential-tools.sh
  SUBYARD_REAL_KEYS_TOOLS_DIR="$temp/tools" bash tests/real-host/ssh-credential-peer.sh
  find "$temp" -depth -delete
  trap - EXIT
  printf 'ok: VM2 suite, SSH RPC and real credential adapters\n'
)

install_peer_wrapper() {
  local wrapper="$PEER_ROOT/yard-wrapper"
  if sudo -n test -e /usr/local/bin/yard; then
    sudo -n grep -Fqx "# $MARKER" /usr/local/bin/yard \
      || die '/usr/local/bin/yard already exists and is not this fixture'
    return
  fi
  {
    printf '#!/usr/bin/env bash\n# %s\n' "$MARKER"
    printf 'export HOME=%q SUBYARD_OPERATOR_HOME=%q SUBYARD_CONFIG_HOME=%q\n' \
      "$PEER_ROOT/home" "$PEER_ROOT/home" "$PEER_ROOT/config"
    printf 'export SUBYARD_HOME=%q HOST_BASE=%q RESTRICTED_DISK_PATHS=%q\n' \
      "$PEER_ROOT/data" "$PEER_ROOT/host-data" "$PEER_ROOT/host-data"
    printf 'export SUBYARD_KEYS_ROOT=%q SUBYARD_KEYS_TOOLS_DIR=%q SUBYARD_KEYS_CONSUMER_ROOT=%q\n' \
      "$PEER_ROOT/keys" "$PEER_ROOT/tools" "$PEER_ROOT/consumer"
    printf 'export SUBYARD_REPOSITORY_ROOT=%q SUBYARD_NO_AUDIT=1\n' "$PEER_ROOT/src"
    printf 'exec %q/bin/yard "$@"\n' "$PEER_ROOT/src"
  } > "$wrapper"
  chmod 0755 "$wrapper"
  sudo -n install -m 0755 "$wrapper" /usr/local/bin/yard
}

bootstrap_peer_keys() {
  HOME="$PEER_ROOT/home" SUBYARD_OPERATOR_HOME="$PEER_ROOT/home" \
    SUBYARD_CONFIG_HOME="$PEER_ROOT/config" SUBYARD_HOME="$PEER_ROOT/data" \
    HOST_BASE="$PEER_ROOT/host-data" RESTRICTED_DISK_PATHS="$PEER_ROOT/host-data" \
    SUBYARD_KEYS_ROOT="$PEER_ROOT/keys" SUBYARD_KEYS_TOOLS_DIR="$PEER_ROOT/tools" \
    CONTROL_PLANE_ROOT="$PEER_ROOT/src" SCRIPT_DIR="$PEER_ROOT/src/scripts" bash -c '
      set -euo pipefail
      . "$CONTROL_PLANE_ROOT/tests/helpers/source-control-plane.sh"
      . "$CONTROL_PLANE_ROOT/tests/helpers/source-credentials.sh"
      keys_init_store
    ' >/dev/null
}

peer_prepare() {
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  clean_tree "$PEER_ROOT" "$MARKER"
  install -d -m 0700 "$PEER_ROOT/src" "$PEER_ROOT/home" "$PEER_ROOT/config/yards"
  printf '%s\n' "$MARKER" > "$PEER_ROOT/.subyard-p0-marker"
  cp -a "$ROOT/." "$PEER_ROOT/src/"
  YARD_BUILD_VERSION="p0-vm-$SUBYARD_E2E_VM" \
    "$PEER_ROOT/src/scripts/build-engine.sh" --force --output "$PEER_ROOT/yard-engine" >/dev/null
  SUBYARD_HOME="$PEER_ROOT/data" SUBYARD_KEYS_TOOLS_DIR="$PEER_ROOT/tools" \
    bash "$PEER_ROOT/src/scripts/install-key-tools.sh" -y >/dev/null
  bootstrap_peer_keys
  printf 'YARD_TYPE=remote\nREMOTE_DEST=dev@%s\nSSH_PORT=3222\n' "$PEER_IP" \
    > "$PEER_ROOT/config/yards/peer.env"
  install_peer_wrapper
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "dev@$PEER_IP" -- true
  printf 'ok: VM%s cross-owner fixture ready\n' "$SUBYARD_E2E_VM"
}

append_frame() { # json file
  local payload="$1" file="$2" hex
  hex="$(printf '%08x' "${#payload}")"
  { printf '%b' "\\x${hex:0:2}\\x${hex:2:2}\\x${hex:4:2}\\x${hex:6:2}"; printf '%s' "$payload"; } >> "$file"
}

decode_frames() { # framed-input json-lines-output
  local input="$1" output="$2" offset=0 total header size
  total="$(stat -c '%s' "$input")"; : > "$output"
  while [ "$offset" -lt "$total" ]; do
    header="$(dd if="$input" bs=1 skip="$offset" count=4 status=none | od -An -tx1 | tr -d ' \n')"
    [ "${#header}" = 8 ] || die 'RPC frame header is truncated'
    size=$((16#$header)); [ $((offset + 4 + size)) -le "$total" ] || die 'RPC frame body is truncated'
    dd if="$input" bs=1 skip=$((offset + 4)) count="$size" status=none >> "$output"
    printf '\n' >> "$output"
    offset=$((offset + 4 + size))
  done
}

peer_rpc() {
  local request response body remote_root remote_engine
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  remote_root="/tmp/subyard-p0-peer-$TOKEN"
  remote_engine="$remote_root/yard-engine"
  request="$PEER_ROOT/rpc-request"; response="$PEER_ROOT/rpc-response"; body="$PEER_ROOT/rpc-body"
  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  ssh -o BatchMode=yes "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="$remote_root/src" \
    "$remote_engine" rpc --stdio \
    < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -e --arg version "p0-vm-$((3 - SUBYARD_E2E_VM))" \
    'select(.id=="negotiate" and .error==null and .result.version==1 and .result.engineVersion==$version)' \
    "$body" >/dev/null \
    || die 'cross-owner negotiation failed'

  : > "$request"
  append_frame '{"version":2,"type":"request","id":"bad","method":"rpc.negotiate"}' "$request"
  ssh -o BatchMode=yes "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="$remote_root/src" \
    "$remote_engine" rpc --stdio \
    < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -e 'select(.id=="bad" and .error.code=="incompatible_version")' "$body" >/dev/null \
    || die 'version skew was not rejected'

  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  append_frame '{"version":1,"type":"request","id":"events","operationId":"operation-events","method":"incus.events"}' "$request"
  append_frame '{"version":1,"type":"cancel","id":"cancel","operationId":"operation-events"}' "$request"
  ssh -o BatchMode=yes "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="$remote_root/src" \
    "$remote_engine" rpc --stdio < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -s -e 'any(.[]; .id=="cancel" and .result.cancelled=="operation-events") and
    any(.[]; .id=="events" and .operationId=="operation-events" and .error.code=="cancelled")' \
    "$body" >/dev/null || die 'live RPC cancellation failed'

  printf '\0\0\0\20broken' | ssh -o BatchMode=yes "dev@$PEER_IP" -- \
    env SUBYARD_REPOSITORY_ROOT="$remote_root/src" "$remote_engine" rpc --stdio >/dev/null 2>&1 || true
  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  append_frame '{"version":1,"type":"request","id":"snapshot","method":"system.snapshot"}' "$request"
  ssh -o BatchMode=yes "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="$remote_root/src" \
    "$remote_engine" rpc --stdio \
    < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -s -e 'any(.[]; .id=="negotiate" and .error==null) and
    any(.[]; .id=="snapshot" and .type=="event" and .event=="snapshot.ready") and
    any(.[]; .id=="snapshot" and .type=="response" and .error==null and .result.revision>=1)' \
    "$body" >/dev/null || die 'RPC did not renegotiate and resync after disconnect'
  printf 'ok: VM%s cross-owner RPC, cancellation, skew and resync\n' "$SUBYARD_E2E_VM"
}

peer_credentials() {
  local expected credential remote_hash source_hash
  [ "$SUBYARD_E2E_VM" = 1 ] || die 'credential controller requires VM1'
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  expected="$PEER_ROOT/synthetic-credential"
  printf 'subyard-synthetic-p0-cross-owner\n' > "$expected"; chmod 0600 "$expected"
  /usr/local/bin/yard keys trust @peer --yes >/dev/null
  /usr/local/bin/yard keys add p0-cross-owner --kind file --zone p0-cross-owner \
    --consumer staging-env --file "$expected" --yes >/dev/null
  credential="$(/usr/local/bin/yard keys list | awk -F '\t' '$8=="p0-cross-owner" {print $1}')"
  [ -n "$credential" ] || die 'cross-owner credential was not created'
  /usr/local/bin/yard keys sync @peer --now >/dev/null
  ssh -o BatchMode=yes "dev@$PEER_IP" -- bash -lc \
    "$(printf '%q' 'yard keys materialize p0-cross-owner --yes')" >/dev/null
  source_hash="$(sha256sum "$expected" | awk '{print $1}')"
  remote_hash="$(ssh -o BatchMode=yes "dev@$PEER_IP" -- sha256sum \
    "/tmp/subyard-p0-peer-$TOKEN/consumer/config/staging/p0-cross-owner.env" | awk '{print $1}')"
  [ "$source_hash" = "$remote_hash" ] || die 'cross-owner credential materialization differs'
  /usr/local/bin/yard keys revoke "$credential" --yes >/dev/null
  /usr/local/bin/yard keys sync @peer --now >/dev/null
  ssh -o BatchMode=yes "dev@$PEER_IP" -- bash -lc \
    "$(printf '%q' 'yard keys materialize p0-cross-owner --yes')" >/dev/null
  ! ssh -o BatchMode=yes "dev@$PEER_IP" -- test -e \
    "/tmp/subyard-p0-peer-$TOKEN/consumer/config/staging/p0-cross-owner.env" \
    || die 'revoked cross-owner credential remains materialized'
  printf 'ok: real cross-owner credential trust, sync and revoke\n'
}

peer_clean() {
  if sudo -n test -e /usr/local/bin/yard && sudo -n grep -Fqx "# $MARKER" /usr/local/bin/yard; then
    sudo -n find /usr/local/bin/yard -delete
  fi
  clean_tree "$PEER_ROOT" "$MARKER"
}

case "$MODE" in
  owner) owner ;;
  controller) controller ;;
  peer-prepare) peer_prepare ;;
  peer-rpc) peer_rpc ;;
  peer-credentials) peer_credentials ;;
  peer-clean) peer_clean ;;
  *) die 'mode must be owner, controller, peer-prepare, peer-rpc, peer-credentials or peer-clean' ;;
esac
