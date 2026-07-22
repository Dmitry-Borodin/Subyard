#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TOKEN="${2:-}"
PEER_IP="${3:-}"
PEER_ROOT="/tmp/subyard-p0-peer-$TOKEN"
MARKER="subyard-p0-$TOKEN"
PEER_INCUS_MARKER="$PEER_ROOT/.subyard-p0-incus-init"
PEER_INCUS_POOL="subyard-p0-$TOKEN"
OWNER_BASELINE_IMAGES=''
OWNER_BASELINE_CAPTURED=0

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
  printf '%s\nbase\n' "$MARKER" > "$source/result.txt"
  ./bin/yard -Y e2e-yard sync "$source" --yes >/dev/null
  ./bin/yard -Y e2e-yard shell "$source" --yes -- sh -c 'printf "mutated\n" >> result.txt'
  ./bin/yard -Y e2e-yard export "$source" --yes >/dev/null
  patch="$(grep -RIl -- 'mutated' "${SUBYARD_HOME:-$HOME/.subyard}/exports" | head -n1)"
  [ -n "$patch" ] || die 'project export did not contain the guest change'
  ./bin/yard -Y e2e-yard remove "$source" --yes >/dev/null
  find "$patch" -delete
  clean_tree "$source" "$MARKER"
}

owner_cleanup() {
  local rc=$? source="/tmp/subyard-p0-project-$TOKEN" patch fingerprint cleanup_failed=0
  trap - EXIT
  set +e
  clean_tree "$source" "$MARKER" || cleanup_failed=1
  if [ -d "${SUBYARD_HOME:-$HOME/.subyard}/exports" ]; then
    while IFS= read -r patch; do find "$patch" -delete || cleanup_failed=1; done \
      < <(grep -RIl -- "$MARKER" "${SUBYARD_HOME:-$HOME/.subyard}/exports" 2>/dev/null)
  fi
  if [ -f private/yards/e2e-yard.env ] \
    && incus project show subyard-e2e-yard >/dev/null 2>&1; then
    ./bin/yard -Y e2e-yard teardown --yes >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [ "$OWNER_BASELINE_CAPTURED" = 1 ]; then
    while IFS= read -r fingerprint; do
      [ -n "$fingerprint" ] || continue
      printf '%s\n' "$OWNER_BASELINE_IMAGES" | grep -Fxq "$fingerprint" \
        || incus image delete "$fingerprint" --project default >/dev/null 2>&1 \
        || cleanup_failed=1
    done < <(incus image list --project default --format csv -c f)
  fi
  [ "$cleanup_failed" = 0 ] || rc=3
  exit "$rc"
}

install_owner_runtime() {
  local arch release artifact
  arch="$(go env GOARCH)"
  release="$ROOT/.build/p0-owner-release"
  artifact="$release/subyard-p0-owner-linux-$arch"
  scripts/package-engine.sh --output-dir "$release" --version p0-owner --arch "$arch" >/dev/null
  scripts/install-runtime-release.sh \
    --bundle "$artifact.tar.gz" \
    --checksum "$artifact.tar.gz.sha256" \
    --manifest "$artifact.tar.gz.manifest.json" \
    --provenance "$artifact.tar.gz.provenance.json" >/dev/null
}

owner() (
  [ "$SUBYARD_E2E_VM" = 1 ] || die 'owner lane requires VM1'
	trap owner_cleanup EXIT
	YARD_BUILD_VERSION=p0-owner scripts/build-engine.sh --force >/dev/null
	install_owner_runtime
	ensure_owner_incus
	OWNER_BASELINE_IMAGES="$(incus image list --project default --format csv -c f)"
  OWNER_BASELINE_CAPTURED=1
  install -d -m 0700 private/yards
  printf 'YARD_TEMPLATE=e2e-vms\nSSH_PORT=2223\n' > private/yards/e2e-yard.env
  ./bin/yard -Y e2e-yard init --yes
  ./bin/yard -Y e2e-yard start --yes
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
)

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
    printf 'export SUBYARD_REPOSITORY_ROOT=%q YARD_ENGINE_PATH=%q SUBYARD_NO_AUDIT=1\n' \
      "$PEER_ROOT/src" "$PEER_ROOT/yard-engine"
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

reexec_with_incus_group() {
	local resume_mode="$1" command
	command -v sg >/dev/null 2>&1 || die 'sg is required to activate incus-admin membership'
	printf -v command 'exec env SUBYARD_E2E_VM=%q bash %q %q %q %q' \
		"$SUBYARD_E2E_VM" "$ROOT/dev/e2e/p0-guest.sh" "$resume_mode" "$TOKEN" "$PEER_IP"
	exec sg incus-admin -c "$command"
}

ensure_incus() {
	local state_root="$1" install_marker="${2:-}" resume_mode="$3"
	if command -v incus >/dev/null 2>&1 \
		&& ! id -nG | tr ' ' '\n' | grep -qx incus-admin \
		&& id -nG "$(id -un)" | tr ' ' '\n' | grep -qx incus-admin; then
		reexec_with_incus_group "$resume_mode"
	fi
	if incus info >/dev/null 2>&1; then
    if dpkg --compare-versions "$(incus --version)" ge 6.0.6; then return 0; fi
    printf '  [ .. ] VM%s: upgrading Incus to the supported LTS\n' "$SUBYARD_E2E_VM"
    bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly --upgrade-only
    dpkg --compare-versions "$(incus --version)" ge 6.0.6 \
      || die 'Incus upgrade did not reach 6.0.6'
    return
  fi
  if command -v incus >/dev/null 2>&1 || [ -S /var/lib/incus/unix.socket ]; then
    die 'Incus exists but is unavailable to the peer user'
  fi
	[ -z "$install_marker" ] || printf '%s\n' "$MARKER" > "$install_marker"
	printf '  [ .. ] VM%s: initializing the Incus owner API\n' "$SUBYARD_E2E_VM"
	SUBYARD_USER="$(id -un)" SUBYARD_HOME="$state_root" \
		STORAGE_PATH="$state_root/storage" \
		bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly
	id -nG | tr ' ' '\n' | grep -qx incus-admin || reexec_with_incus_group "$resume_mode"
}

ensure_owner_incus() { ensure_incus "$HOME/.subyard/incus" '' owner; }
ensure_peer_incus() { ensure_incus "$PEER_ROOT/incus-home" "$PEER_INCUS_MARKER" peer-prepare-resume; }

ensure_peer_snapshot_fixture() {
  if incus project show subyard >/dev/null 2>&1; then
    [ "$(incus project get subyard user.subyard.p0)" = "$MARKER" ] \
      || die "Incus project 'subyard' is not the peer fixture"
    [ "$(incus config get yard user.subyard.p0 --project subyard)" = "$MARKER" ] \
      || die "Incus instance 'subyard/yard' is not the peer fixture"
    return
  fi
  install -d -m 0700 "$PEER_ROOT/incus-pool"
  incus storage create "$PEER_INCUS_POOL" dir source="$PEER_ROOT/incus-pool" --project default >/dev/null
  incus project create subyard -c features.images=false -c features.profiles=false \
    -c features.storage.volumes=false -c user.subyard.p0="$MARKER" >/dev/null
  incus init --empty yard --project subyard --storage "$PEER_INCUS_POOL" --no-profiles \
    -c user.subyard.p0="$MARKER" >/dev/null
}

cleanup_peer_snapshot_fixture() {
  incus project show subyard >/dev/null 2>&1 || return 0
  [ "$(incus project get subyard user.subyard.p0)" = "$MARKER" ] \
    || die "refusing to clean unrelated Incus project 'subyard'"
  [ "$(incus config get yard user.subyard.p0 --project subyard)" = "$MARKER" ] \
    || die "refusing to clean unrelated Incus instance 'subyard/yard'"
  incus delete yard --project subyard --force >/dev/null
  incus project delete subyard >/dev/null
  incus storage delete "$PEER_INCUS_POOL" --project default >/dev/null
}

cleanup_peer_incus() {
  [ -e "$PEER_INCUS_MARKER" ] || return 0
  [ "$(cat "$PEER_INCUS_MARKER" 2>/dev/null)" = "$MARKER" ] \
    || die 'refusing to clean unmarked peer Incus state'
  [ -z "$(incus list --all-projects --format csv -c n)" ] \
    || die 'peer Incus still has instances'
  if incus profile device list default --project default 2>/dev/null | grep -qx eth0; then
    incus profile device remove default eth0 --project default >/dev/null
  fi
  if incus profile device list default --project default 2>/dev/null | grep -qx root; then
    incus profile device remove default root --project default >/dev/null
  fi
  incus network show incusbr0 --project default >/dev/null 2>&1 \
    && incus network delete incusbr0 --project default >/dev/null
  incus storage show default --project default >/dev/null 2>&1 \
    && incus storage delete default --project default >/dev/null
  sudo -n find "$PEER_ROOT/incus-home" -depth -delete 2>/dev/null || true
}

peer_prepare() {
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  peer_clean
  install -d -m 0700 "$PEER_ROOT/src" "$PEER_ROOT/home" "$PEER_ROOT/config/yards"
	printf '%s\n' "$MARKER" > "$PEER_ROOT/.subyard-p0-marker"
	ensure_peer_incus
	peer_prepare_finish
}

peer_prepare_finish() {
	ensure_peer_snapshot_fixture
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
  if ! jq -s -e 'any(.[]; .id=="negotiate" and .error==null) and
    any(.[]; .id=="snapshot" and .type=="event" and .event=="snapshot.ready") and
    any(.[]; .id=="snapshot" and .type=="response" and .error==null and .result.revision>=1)' \
    "$body" >/dev/null; then
    printf 'p0-guest: resync frames:\n' >&2
    sed -n '1,12p' "$body" >&2
    die 'RPC did not renegotiate and resync after disconnect'
  fi
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
  cleanup_peer_snapshot_fixture
  cleanup_peer_incus
  clean_tree "$PEER_ROOT" "$MARKER"
}

case "$MODE" in
  owner) owner ;;
  controller) controller ;;
  peer-prepare) peer_prepare ;;
  peer-prepare-resume) peer_prepare_finish ;;
  peer-rpc) peer_rpc ;;
  peer-credentials) peer_credentials ;;
  peer-clean) peer_clean ;;
  *) die 'mode must be owner, controller, peer-prepare, peer-rpc, peer-credentials or peer-clean' ;;
esac
