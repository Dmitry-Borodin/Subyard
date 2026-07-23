#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TOKEN="${2:-}"
PEER_IP="${3:-}"
PEER_PUBLIC_KEY="${4:-}"
PEER_HOST_KEY="${5:-}"
PEER_ROOT="/tmp/subyard-p0-peer-$TOKEN"
PEER_DATA_ROOT="$HOME/.cache/subyard-p0-peer-$TOKEN"
MARKER="subyard-p0-$TOKEN"
PEER_INCUS_MARKER="$PEER_ROOT/.subyard-p0-incus-init"
PEER_INCUS_POOL="subyard-p0-$TOKEN"
OWNER_YARD_DIR="${SUBYARD_CONFIG_HOME:-$HOME/.config/subyard}/yards"
RENAME_BASE_REVISION="7c67ee3f423cf9f1596c2f5191f462d2b70adcdc"
RENAME_BASE_ROOT="/tmp/subyard-p0-rename-base-$TOKEN"
PEER_SSH_DIR="$PEER_ROOT/ssh"
PEER_YARD_ENTRY="$HOME/.local/bin/yard"
PEER_YARD_BACKUP="$PEER_ROOT/user-yard-entry.backup"
PEER_YARD_STATE="$PEER_ROOT/.user-yard-entry-state"
PEER_AUTH_STATE="$PEER_ROOT/.authorized-keys-state"
PEER_CONFIG_STATE="$PEER_ROOT/.ssh-config-state"
PEER_REAL_YARD_MARKER="$PEER_ROOT/.subyard-p0-real-yard"
OWNER_BASELINE_IMAGES=''
OWNER_BASELINE_CAPTURED=0
OWNER_BASE_IMAGE="${P0_REAL_INCUS_CONTAINER_CACHE_ALIAS:-subyard-e2e-debian-13-cloud-container}"

die() { printf 'p0-guest: %s\n' "$*" >&2; exit 2; }
valid_token() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_ip() { [[ "$1" =~ ^[0-9a-fA-F:.]+$ ]]; }
normalized_ed25519() {
  local value="$1" type blob rest
  read -r type blob rest <<<"$value"
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] \
    || return 1
  printf '%s %s\n' "$type" "$blob"
}
valid_token "$TOKEN" || die 'allocation token must be numeric'
[ -n "${SUBYARD_E2E_VM:-}" ] || die 'run through dev/agent-e2e.sh'

clean_tree() { # guarded path marker
  local path="$1" marker="$2"
  case "$path" in /tmp/subyard-p0-*) ;; *) die "unsafe cleanup path $path" ;; esac
  [ ! -e "$path" ] || [ "$(cat "$path/.subyard-p0-marker" 2>/dev/null)" = "$marker" ] \
    || die "refusing to clean unmarked path $path"
  [ ! -e "$path" ] || sudo -n find "$path" -depth -delete
}

clean_peer_data() {
  case "$PEER_DATA_ROOT" in "$HOME/.cache/subyard-p0-"*) ;;
    *) die "unsafe peer data path $PEER_DATA_ROOT" ;;
  esac
  [ ! -e "$PEER_DATA_ROOT" ] \
    || [ "$(cat "$PEER_ROOT/.subyard-p0-marker" 2>/dev/null)" = "$MARKER" ] \
    || die "refusing to clean unmarked peer data $PEER_DATA_ROOT"
  [ ! -e "$PEER_DATA_ROOT" ] || sudo -n find "$PEER_DATA_ROOT" -depth -delete
}

owner_project_contract() {
  local source="/tmp/subyard-p0-project-$TOKEN" patch
  clean_tree "$source" "$MARKER"
  install -d -m 0700 "$source"
  printf '%s\n' "$MARKER" > "$source/.subyard-p0-marker"
  printf '%s\nbase\n' "$MARKER" > "$source/result.txt"
  ./bin/yard -Y test-yard sync "$source" --target openclaw --yes >/dev/null
  ./bin/yard -Y test-yard up "$source" --yes >/dev/null
  ./bin/yard -Y test-yard info "$source" | grep -Fq '"profile": "openclaw"'
  ./bin/yard -Y test-yard down "$source" --yes >/dev/null
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard -Y test-yard code "$source" --yes >/dev/null
  ./bin/yard -Y test-yard shell "$source" --yes -- sh -c 'printf "mutated\n" >> result.txt'
  ./bin/yard -Y test-yard export "$source" --yes >/dev/null
  patch="$(grep -RIl -- 'mutated' "${SUBYARD_HOME:-$HOME/.subyard}/exports" | head -n1)"
  [ -n "$patch" ] || die 'project export did not contain the guest change'
  ./bin/yard -Y test-yard remove "$source" --yes >/dev/null
  find "$patch" -delete
  clean_tree "$source" "$MARKER"
}

owner_cleanup() {
  local rc=$? source="/tmp/subyard-p0-project-$TOKEN" patch fingerprint yard registration
  local cleanup_failed=0
  trap - EXIT
  set +e
  clean_tree "$source" "$MARKER" || cleanup_failed=1
  clean_tree "$RENAME_BASE_ROOT" "$MARKER" || cleanup_failed=1
  if [ -d "${SUBYARD_HOME:-$HOME/.subyard}/exports" ]; then
    while IFS= read -r patch; do find "$patch" -delete || cleanup_failed=1; done \
      < <(grep -RIl -- "$MARKER" "${SUBYARD_HOME:-$HOME/.subyard}/exports" 2>/dev/null)
  fi
  for yard in e2e-yard test-yard; do
    registration="$OWNER_YARD_DIR/$yard.env"
    [ -f "$registration" ] || continue
    grep -Fqx "# $MARKER" "$registration" || { cleanup_failed=1; continue; }
    if grep -Fqx 'YARD_TEMPLATE=e2e-vms' "$registration"; then
      sed -i 's/^YARD_TEMPLATE=e2e-vms$/YARD_TEMPLATE=test-vms/' "$registration" \
        || cleanup_failed=1
    fi
    if incus project show "subyard-$yard" >/dev/null 2>&1; then
      ./bin/yard -Y "$yard" teardown --yes >/dev/null 2>&1 || cleanup_failed=1
    fi
    find "$registration" -delete || cleanup_failed=1
  done
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

write_owner_registration() { # <yard> <template> <ssh-port>
  local yard="$1" template="$2" port="$3" registration
  registration="$OWNER_YARD_DIR/$yard.env"
  install -d -m 0700 "$OWNER_YARD_DIR"
  if [ -e "$registration" ]; then
    grep -Fqx "# $MARKER" "$registration" \
      || die "refusing to replace unrelated registration $registration"
  fi
  printf '# %s\nYARD_TEMPLATE=%s\nSSH_PORT=%s\nAGENTS=none\nDEV_UID=1001\nBASE_IMAGE=%s\nBASE_IMAGE_FALLBACK=%s\n' \
    "$MARKER" "$template" "$port" "$OWNER_BASE_IMAGE" "$OWNER_BASE_IMAGE" \
    > "$registration"
}

install_rename_base_runtime() {
  local arch release bundle
  clean_tree "$RENAME_BASE_ROOT" "$MARKER"
  install -d -m 0700 "$RENAME_BASE_ROOT"
  printf '%s\n' "$MARKER" > "$RENAME_BASE_ROOT/.subyard-p0-marker"
  git -C "$RENAME_BASE_ROOT" init -q
  git -C "$RENAME_BASE_ROOT" remote add origin https://github.com/Dmitry-Borodin/Subyard.git
  git -C "$RENAME_BASE_ROOT" fetch -q --depth 1 origin "$RENAME_BASE_REVISION"
  git -C "$RENAME_BASE_ROOT" checkout -q --detach FETCH_HEAD
  [ "$(git -C "$RENAME_BASE_ROOT" rev-parse HEAD)" = "$RENAME_BASE_REVISION" ] \
    || die 'rename-base checkout resolved to the wrong revision'
  arch="$(go env GOARCH)"
  release="$RENAME_BASE_ROOT/.build/p0-rename-base-release"
  bundle="$release/subyard-p0-rename-base-linux-$arch.tar.gz"
  "$RENAME_BASE_ROOT/scripts/package-engine.sh" \
    --output-dir "$release" --version p0-rename-base --arch "$arch" >/dev/null
  "$RENAME_BASE_ROOT/scripts/install-runtime-release.sh" \
    --bundle "$bundle" \
    --checksum "$bundle.sha256" \
    --manifest "$bundle.manifest.json" \
    --provenance "$bundle.provenance.json" >/dev/null
}

install_owner_runtime() {
  local arch release artifact
  arch="$(go env GOARCH)"
  release="$ROOT/.build/p0-owner-release"
  artifact="$release/subyard-p0-owner-linux-$arch"
  dev/package-engine.sh --output-dir "$release" --version p0-owner --arch "$arch" >/dev/null
  scripts/install-runtime-release.sh \
    --bundle "$artifact.tar.gz" \
    --checksum "$artifact.tar.gz.sha256" \
    --manifest "$artifact.tar.gz.manifest.json" \
    --provenance "$artifact.tar.gz.provenance.json" >/dev/null
}

owner_profile_migration_contract() {
  local old_yard runtime_root="${SUBYARD_HOME:-$HOME/.subyard}/runtime" diagnostic yard_info
  install_rename_base_runtime
  old_yard="$runtime_root/current/bin/yard"
  [ "$("$old_yard" --version)" = 'yard p0-rename-base' ] \
    || die 'pre-rename runtime was not installed'

  write_owner_registration e2e-yard e2e-vms 2224
  "$old_yard" -Y e2e-yard init --yes
  "$old_yard" -Y e2e-yard check
  "$old_yard" -Y e2e-yard start --yes
  "$old_yard" -Y e2e-yard status >/dev/null

  install_owner_runtime
  [ "$("$runtime_root/current/bin/yard" --version)" = 'yard p0-owner' ] \
    || die 'current runtime was not installed over the pre-rename runtime'
  if diagnostic="$(./bin/yard -Y e2e-yard status 2>&1)"; then
    die 'current runtime accepted the retired e2e-vms registration'
  fi
  for expected in \
    "$OWNER_YARD_DIR/e2e-yard.env" \
    'YARD_TEMPLATE=test-vms' \
    'yard -Y e2e-yard check' \
    'yard -Y e2e-yard test-vms down' \
    'yard -Y e2e-yard teardown'; do
    grep -Fq "$expected" <<<"$diagnostic" \
      || die "live retired-template diagnostic omitted: $expected"
  done

  write_owner_registration e2e-yard test-vms 2224
  ./bin/yard -Y e2e-yard check
  ./bin/yard -Y e2e-yard status >/dev/null

  write_owner_registration test-yard test-vms 2223
  yard_info="$(./bin/yard -Y test-yard _info)"
  jq -e '.name == "test-yard" and .instance == "yard-test-yard" and
    .project == "subyard-test-yard" and .sshHost == "yard-test-yard" and .sshPort == 2223' \
    <<<"$yard_info" >/dev/null \
    || die "test-yard coexistence context is wrong: $yard_info"
  yard_info="$(./bin/yard -Y e2e-yard _info)"
  jq -e '.name == "e2e-yard" and .instance == "yard-e2e-yard" and
    .project == "subyard-e2e-yard" and .sshHost == "yard-e2e-yard" and .sshPort == 2224' \
    <<<"$yard_info" >/dev/null \
    || die "e2e-yard rollback context is wrong: $yard_info"

  ./bin/yard -Y e2e-yard test-vms status --yes
  ./bin/yard -Y e2e-yard test-vms down --yes
  ./bin/yard -Y e2e-yard teardown --yes
  ! incus project show subyard-e2e-yard >/dev/null 2>&1 \
    || die 'old e2e-yard project remains after migrated teardown'
  [ ! -e "${SUBYARD_CONFIG_HOME:-$HOME/.config/subyard}/yards/e2e-yard/projects" ] \
    || die 'old e2e-yard state remains after teardown'
  [ ! -e "$HOME/.ssh/subyard-e2e-yard.config" ] \
    || die 'old e2e-yard route remains after teardown'
  find "$OWNER_YARD_DIR/e2e-yard.env" -delete
  ./bin/yard -Y test-yard init --yes
  ./bin/yard -Y test-yard status >/dev/null
  printf 'ok: pre-rename runtime upgraded, coexisted and retired e2e-yard explicitly\n'
}

prepare_owner_image_cache_project() {
  local project=subyard-e2e-yard
  if incus project show "$project" >/dev/null 2>&1; then
    incus project delete "$project" >/dev/null 2>&1 \
      || die "refusing to replace non-empty owner project $project"
    printf '  [ ok ] removed empty owner project residue %s\n' "$project"
  fi
  incus image info "$OWNER_BASE_IMAGE" --project default >/dev/null 2>&1 \
    || die "test-owned base image alias $OWNER_BASE_IMAGE is unavailable"
  incus project create "$project" \
    -c features.images=false -c user.subyard.p0-image-cache="$MARKER" >/dev/null
}

owner() (
  [ "$SUBYARD_E2E_VM" = 1 ] || die 'owner lane requires VM1'
	trap owner_cleanup EXIT
	YARD_BUILD_VERSION=p0-owner dev/build-engine.sh --force >/dev/null
	ensure_owner_incus
	OWNER_BASELINE_IMAGES="$(incus image list --project default --format csv -c f)"
  OWNER_BASELINE_CAPTURED=1
	bash dev/e2e/p0-real-incus.sh
  prepare_owner_image_cache_project
  owner_profile_migration_contract
  ./bin/yard -Y test-yard start --yes
  SUBYARD_E2E_LEGACY_FIXTURE=1 \
    bash dev/e2e/seed-test-vms-legacy-state.sh subyard-test-yard yard-test-yard
  ./bin/yard -Y test-yard init --yes
  ./bin/yard -Y test-yard check
  ./bin/yard -Y test-yard init --yes
  [ "$(incus exec yard-test-yard --project subyard-test-yard -- stat -c '%U:%G:%a' /var/lib/subyard/test-vms)" = root:root:700 ] \
    || die 'nested state permissions did not converge'
  ! incus exec yard-test-yard --project subyard-test-yard -- id -nG dev | tr ' ' '\n' \
    | grep -Eq '^(incus-admin|yard)$' || die 'dev retained a privileged L1 group'
  owner_project_contract
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard --version >/dev/null
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard -Y test-yard list >/dev/null
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin ./bin/yard -Y test-yard status >/dev/null
  bash tests/engine-release.sh
  ./bin/yard -Y test-yard teardown --yes
  ! incus project show subyard-test-yard >/dev/null 2>&1 || die 'candidate project remains after teardown'
  [ -x "$HOME/.subyard/runtime/current/bin/yard" ] \
    || die 'last-yard teardown removed the installed candidate runtime'
  env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$HOME/.subyard/runtime/current/bin/yard" --version >/dev/null \
    || die 'installed candidate runtime is unusable after last-yard teardown'
  printf 'ok: VM1 owner, legacy upgrade, lifecycle, Incus and rollback\n'
)

controller() (
  local temp
  [ "$SUBYARD_E2E_VM" = 2 ] || die 'controller lane requires VM2'
  shellcheck -x -S warning dev/e2e/p0-acceptance.sh dev/e2e/p0-guest.sh \
    dev/e2e/p0-real-incus.sh dev/e2e/p0-source-upgrade.sh \
    dev/build-engine.sh tests/build-engine.sh \
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
  [ ! -e "$PEER_YARD_STATE" ] && [ ! -e "$PEER_YARD_BACKUP" ] \
    && [ ! -L "$PEER_YARD_BACKUP" ] || die 'peer yard entry backup is already staged'
  [ ! -d "$PEER_YARD_ENTRY" ] || die 'peer yard entry is a directory'
  install -d -m 0755 "$(dirname "$PEER_YARD_ENTRY")"
  if [ -e "$PEER_YARD_ENTRY" ] || [ -L "$PEER_YARD_ENTRY" ]; then
    printf 'saving\n' > "$PEER_YARD_STATE"
    mv "$PEER_YARD_ENTRY" "$PEER_YARD_BACKUP"
    printf 'saved\n' > "$PEER_YARD_STATE"
  else
    printf 'absent\n' > "$PEER_YARD_STATE"
  fi
  {
    printf '#!/usr/bin/env bash\n# %s\n' "$MARKER"
    printf 'export HOME=%q SUBYARD_OPERATOR_HOME=%q SUBYARD_CONFIG_HOME=%q\n' \
      "$PEER_ROOT/home" "$PEER_ROOT/home" "$PEER_ROOT/config"
    printf 'export SUBYARD_HOME=%q HOST_BASE=%q RESTRICTED_DISK_PATHS=%q\n' \
      "$PEER_DATA_ROOT" "$PEER_ROOT/host-data" "$PEER_ROOT/host-data"
    printf 'export SUBYARD_KEYS_ROOT=%q SUBYARD_KEYS_TOOLS_DIR=%q SUBYARD_KEYS_CONSUMER_ROOT=%q\n' \
      "$PEER_ROOT/keys" "$PEER_ROOT/tools" "$PEER_ROOT/consumer"
    printf 'export SUBYARD_KEYS_SYSTEMD_SKIP_ENABLE=1 SUBYARD_NO_AUDIT=1\n'
    printf 'exec %q/yard "$@"\n' "$PEER_ROOT/bin"
  } > "$wrapper"
  chmod 0755 "$wrapper"
  install -m 0755 "$wrapper" "$PEER_YARD_ENTRY"
  [ "$(bash -lc 'command -v yard')" = "$PEER_YARD_ENTRY" ] \
    || die "login shell does not resolve the peer CLI through $PEER_YARD_ENTRY"
}

remove_peer_wrapper() {
  local state
  [ -e "$PEER_YARD_STATE" ] || return 0
  state="$(cat "$PEER_YARD_STATE")"
  case "$state" in
    saving)
      if [ -e "$PEER_YARD_BACKUP" ] || [ -L "$PEER_YARD_BACKUP" ]; then
        [ ! -e "$PEER_YARD_ENTRY" ] && [ ! -L "$PEER_YARD_ENTRY" ] \
          || die 'refusing to overwrite the user yard entry during interrupted restore'
        mv "$PEER_YARD_BACKUP" "$PEER_YARD_ENTRY"
      fi
      ;;
    saved|absent)
      if [ -e "$PEER_YARD_ENTRY" ] || [ -L "$PEER_YARD_ENTRY" ]; then
        [ -f "$PEER_YARD_ENTRY" ] && grep -Fqx "# $MARKER" "$PEER_YARD_ENTRY" \
          || die 'refusing to remove a non-fixture user yard entry'
        find "$PEER_YARD_ENTRY" -delete
      fi
      if [ "$state" = saved ]; then
        [ -e "$PEER_YARD_BACKUP" ] || [ -L "$PEER_YARD_BACKUP" ] \
          || die 'saved user yard entry is missing'
        mv "$PEER_YARD_BACKUP" "$PEER_YARD_ENTRY"
      else
        [ ! -e "$PEER_YARD_BACKUP" ] && [ ! -L "$PEER_YARD_BACKUP" ] \
          || die 'unexpected user yard entry backup exists'
      fi
      ;;
    *) die 'peer yard entry backup state is invalid' ;;
  esac
  find "$PEER_YARD_STATE" -delete
}

bootstrap_peer_keys() {
  HOME="$PEER_ROOT/home" SUBYARD_OPERATOR_HOME="$PEER_ROOT/home" \
    SUBYARD_CONFIG_HOME="$PEER_ROOT/config" SUBYARD_HOME="$PEER_DATA_ROOT" \
    HOST_BASE="$PEER_ROOT/host-data" RESTRICTED_DISK_PATHS="$PEER_ROOT/host-data" \
    SUBYARD_KEYS_ROOT="$PEER_ROOT/keys" SUBYARD_KEYS_TOOLS_DIR="$PEER_ROOT/tools" \
    "$PEER_ROOT/bin/yard" _keys-init >/dev/null
}

reexec_with_incus_group() {
	local resume_mode="$1" command resume_script="$ROOT/dev/e2e/p0-guest.sh"
	command -v sg >/dev/null 2>&1 || die 'sg is required to activate incus-admin membership'
	if [ "$resume_mode" = peer-prepare-resume ]; then
		resume_script="$PEER_ROOT/src/dev/e2e/p0-guest.sh"
		[ -r "$resume_script" ] || die 'stable peer source is unavailable for incus-admin resume'
	fi
	printf -v command 'exec env SUBYARD_E2E_VM=%q bash %q %q %q %q' \
		"$SUBYARD_E2E_VM" "$resume_script" "$resume_mode" "$TOKEN" "$PEER_IP"
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
    if ! dpkg --compare-versions "$(incus --version)" ge 6.0.6; then
      printf '  [ .. ] VM%s: upgrading Incus to the supported LTS\n' "$SUBYARD_E2E_VM"
      bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly --upgrade-only
      dpkg --compare-versions "$(incus --version)" ge 6.0.6 \
        || die 'Incus upgrade did not reach 6.0.6'
    fi
    if incus storage show default --project default >/dev/null 2>&1 \
      && incus network show incusbr0 --project default >/dev/null 2>&1; then
      return 0
    fi
		[ -z "$install_marker" ] || printf '%s\n' "$MARKER" > "$install_marker"
    printf '  [ .. ] VM%s: restoring the Incus owner API\n' "$SUBYARD_E2E_VM"
    SUBYARD_USER="$(id -un)" SUBYARD_HOME="$state_root" \
      bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly
    return
  fi
  if command -v incus >/dev/null 2>&1 || [ -S /var/lib/incus/unix.socket ]; then
    [ -z "$install_marker" ] || printf '%s\n' "$MARKER" > "$install_marker"
    printf '  [ .. ] VM%s: reconciling a partial Incus installation\n' "$SUBYARD_E2E_VM"
    SUBYARD_USER="$(id -un)" SUBYARD_HOME="$state_root" \
      bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly
    id -nG | tr ' ' '\n' | grep -qx incus-admin || reexec_with_incus_group "$resume_mode"
    return
  fi
	[ -z "$install_marker" ] || printf '%s\n' "$MARKER" > "$install_marker"
	printf '  [ .. ] VM%s: initializing the Incus owner API\n' "$SUBYARD_E2E_VM"
	SUBYARD_USER="$(id -un)" SUBYARD_HOME="$state_root" \
		bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly
	id -nG | tr ' ' '\n' | grep -qx incus-admin || reexec_with_incus_group "$resume_mode"
}

ensure_owner_incus() { ensure_incus "$HOME/.subyard" '' owner; }
ensure_peer_incus() { ensure_incus "$PEER_DATA_ROOT/incus-home" "$PEER_INCUS_MARKER" peer-prepare-resume; }

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
	local fingerprint source
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
	if incus storage show default --project default >/dev/null 2>&1; then
		source="$(incus storage get default source --project default)"
		case "$source" in
			"$PEER_DATA_ROOT/incus-home/storage"|"$PEER_DATA_ROOT/incus-home/incus/storage") ;;
			*) die "refusing to clean non-peer storage pool at $source" ;;
		esac
		while IFS= read -r fingerprint; do
			[ -n "$fingerprint" ] || continue
			incus image delete "$fingerprint" --project default >/dev/null
		done < <(incus image list --project default --format csv -c f)
		incus network show incusbr0 --project default >/dev/null 2>&1 \
			&& incus network delete incusbr0 --project default >/dev/null
		incus storage delete default --project default >/dev/null
	fi
	[ ! -e "$PEER_DATA_ROOT/incus-home" ] \
		|| sudo -n find "$PEER_DATA_ROOT/incus-home" -depth -delete
}

peer_prepare() {
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  peer_clean
  install -d -m 0700 "$PEER_ROOT/src" "$PEER_ROOT/home" "$PEER_ROOT/config/yards"
	printf '%s\n' "$MARKER" > "$PEER_ROOT/.subyard-p0-marker"
  install -d -m 0700 "$PEER_DATA_ROOT"
	cp -a "$ROOT/." "$PEER_ROOT/src/"
	ensure_peer_incus
	peer_prepare_finish
}

peer_ssh() {
	ssh -i "$PEER_SSH_DIR/id_ed25519" \
		-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="$PEER_SSH_DIR/known_hosts" -o GlobalKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 -o ConnectionAttempts=3 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$@"
}

peer_prepare_finish() {
  local release="$PEER_ROOT/release" version="p0-peer-vm-$SUBYARD_E2E_VM"
	[ -r "$PEER_ROOT/src/tests/helpers/source-control-plane.sh" ] \
		|| die 'stable peer source is incomplete after incus-admin resume'
	ensure_peer_snapshot_fixture
  install -d -m 0700 "$PEER_SSH_DIR"
  if [ ! -e "$PEER_SSH_DIR/id_ed25519" ] && [ ! -e "$PEER_SSH_DIR/id_ed25519.pub" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "$MARKER-vm$SUBYARD_E2E_VM" \
      -f "$PEER_SSH_DIR/id_ed25519"
  fi
  [ -s "$PEER_SSH_DIR/id_ed25519" ] && [ -s "$PEER_SSH_DIR/id_ed25519.pub" ] \
    || die 'synthetic peer SSH identity is incomplete'
  install -d -m 0700 "$release" "$PEER_ROOT/bin"
  "$PEER_ROOT/src/dev/package-engine.sh" --output-dir "$release" --version "$version" >/dev/null
  HOME="$PEER_ROOT/home" SUBYARD_HOME="$PEER_DATA_ROOT" \
    SUBYARD_CONFIG_HOME="$PEER_ROOT/config" YARD_BIN_DIR="$PEER_ROOT/bin" \
    YARD_SHELL_RC="$PEER_ROOT/home/.bashrc" YARD_LOGIN_RC="$PEER_ROOT/home/.profile" \
    YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION="$version" \
    PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$release/subyard-install.sh" --yes >/dev/null
  [ "$(readlink "$PEER_ROOT/bin/yard")" = "$PEER_DATA_ROOT/runtime/current/bin/yard" ] \
    && [ "$("$PEER_ROOT/bin/yard" --version)" = "yard $version" ] \
    || die 'peer standalone release is not active'
  SUBYARD_HOME="$PEER_DATA_ROOT" SUBYARD_KEYS_TOOLS_DIR="$PEER_ROOT/tools" \
    bash "$PEER_DATA_ROOT/runtime/current/scripts/install-key-tools.sh" -y >/dev/null
  bootstrap_peer_keys
  install_peer_wrapper
  printf 'ok: VM%s local cross-owner fixture staged\n' "$SUBYARD_E2E_VM"
}

peer_yard_start() {
  [ "$SUBYARD_E2E_VM" = 2 ] || die 'remote project target requires VM2'
  if [ -e "$PEER_REAL_YARD_MARKER" ]; then
    [ "$(cat "$PEER_REAL_YARD_MARKER" 2>/dev/null)" = "$MARKER" ] \
      || die 'real peer yard resume marker is invalid'
  else
    cleanup_peer_snapshot_fixture
    printf '%s\n' "$MARKER" > "$PEER_REAL_YARD_MARKER"
  fi
  printf 'SSH_PORT=3222\nDEV_UID=1001\nBASE_IMAGE=images:debian/13/cloud\nBASE_IMAGE_FALLBACK=images:debian/13/cloud\nE2E_VM_ENABLED=0\n' \
    > "$PEER_DATA_ROOT/config.env"
  "$PEER_YARD_ENTRY" init --yes
  "$PEER_YARD_ENTRY" start --yes
  printf 'ok: VM2 release-installed remote yard is running\n'
}

peer_info() {
  local identity host type blob comment extra
  [ "$(cat "$PEER_ROOT/.subyard-p0-marker" 2>/dev/null)" = "$MARKER" ] \
    || die 'cross-owner fixture marker is missing'
  read -r type blob comment extra < "$PEER_SSH_DIR/id_ed25519.pub"
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] \
    && [ "$comment" = "$MARKER-vm$SUBYARD_E2E_VM" ] && [ -z "$extra" ] \
    || die 'synthetic peer public key is invalid'
  identity="$type $blob $comment"
  host="$(normalized_ed25519 "$(sudo -n cat /etc/ssh/ssh_host_ed25519_key.pub)")" \
    || die 'VM SSH host key is unavailable or invalid'
  printf 'identity\t%s\nhost\t%s\n' "$identity" "$host"
}

peer_authorize() {
  local type blob comment extra normalized_host authorized="$HOME/.ssh/authorized_keys"
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  read -r type blob comment extra <<<"$PEER_PUBLIC_KEY"
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] \
    && [[ "$comment" =~ ^$MARKER-vm[12]$ ]] && [ -z "$extra" ] \
    || die 'peer synthetic public key is invalid'
  normalized_host="$(normalized_ed25519 "$PEER_HOST_KEY")" \
    || die 'peer SSH host key is invalid'
  [ ! -L "$HOME/.ssh" ] && [ ! -L "$authorized" ] \
    || die 'refusing symlinked SSH authorization paths'
  install -d -m 0700 "$HOME/.ssh" "$PEER_SSH_DIR"
  if [ ! -e "$PEER_AUTH_STATE" ]; then
    if [ -e "$authorized" ]; then
      [ -f "$authorized" ] || die 'SSH authorization target is not a regular file'
      printf 'file\t%s\n' "$(stat -c '%a' "$authorized")" > "$PEER_AUTH_STATE"
    else
      printf 'absent\n' > "$PEER_AUTH_STATE"
    fi
  fi
  touch "$authorized"
  chmod 0600 "$authorized"
  grep -Fqx "$PEER_PUBLIC_KEY" "$authorized" || printf '%s\n' "$PEER_PUBLIC_KEY" >> "$authorized"
  printf '%s\n' "$PEER_PUBLIC_KEY" > "$PEER_SSH_DIR/authorized-peer.pub"
  printf '%s %s\n' "$PEER_IP" "$normalized_host" > "$PEER_SSH_DIR/known_hosts"
  chmod 0600 "$PEER_SSH_DIR/authorized-peer.pub" "$PEER_SSH_DIR/known_hosts"
  install -d -m 0700 "$PEER_ROOT/home/.ssh"
  install -m 0600 "$PEER_SSH_DIR/id_ed25519" "$PEER_ROOT/home/.ssh/id_ed25519"
  install -m 0644 "$PEER_SSH_DIR/id_ed25519.pub" "$PEER_ROOT/home/.ssh/id_ed25519.pub"
  printf '%s %s\n' "$PEER_IP" "$normalized_host" > "$PEER_ROOT/home/.ssh/known_hosts"
  chmod 0600 "$PEER_ROOT/home/.ssh/known_hosts"
}

peer_probe() {
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  printf '  [ .. ] VM%s: probing synthetic SSH path to %s\n' "$SUBYARD_E2E_VM" "$PEER_IP"
  peer_ssh "dev@$PEER_IP" -- true \
    || die "synthetic SSH path to $PEER_IP failed"
  printf 'ok: VM%s synthetic cross-owner SSH path verified\n' "$SUBYARD_E2E_VM"
}

remove_peer_authorization() {
  local authorized="$HOME/.ssh/authorized_keys" peer_key state mode extra temp
  [ -r "$PEER_SSH_DIR/authorized-peer.pub" ] || return 0
  read -r state mode extra < "$PEER_AUTH_STATE" \
    || die 'SSH authorization restore state is missing'
  [ -z "$extra" ] || die 'SSH authorization restore state is invalid'
  case "$state" in
    absent) [ -z "$mode" ] || die 'SSH authorization restore state is invalid' ;;
    file) [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die 'SSH authorization restore mode is invalid' ;;
    *) die 'SSH authorization restore state is invalid' ;;
  esac
  peer_key="$(cat "$PEER_SSH_DIR/authorized-peer.pub")"
  [ -f "$authorized" ] && [ ! -L "$authorized" ] \
    || die 'synthetic peer authorization target is unavailable or unsafe'
  temp="$(mktemp "$HOME/.ssh/.authorized-keys.XXXXXX")"
  awk -v key="$peer_key" '$0 != key' "$authorized" > "$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$authorized"
  if [ "$state" = absent ] && [ ! -s "$authorized" ]; then
    find "$authorized" -delete
  elif [ "$state" = file ]; then
    chmod "$mode" "$authorized"
  fi
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
  local request response body remote_engine
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  remote_engine="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current/bin/yard-engine"
  request="$PEER_ROOT/rpc-request"; response="$PEER_ROOT/rpc-response"; body="$PEER_ROOT/rpc-body"
  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  peer_ssh "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current" \
    "$remote_engine" rpc --stdio \
    < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -e --arg version "p0-peer-vm-$((3 - SUBYARD_E2E_VM))" \
    'select(.id=="negotiate" and .error==null and .result.version==1 and .result.engineVersion==$version)' \
    "$body" >/dev/null \
    || die 'cross-owner negotiation failed'

  : > "$request"
  append_frame '{"version":2,"type":"request","id":"bad","method":"rpc.negotiate"}' "$request"
  peer_ssh "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current" \
    "$remote_engine" rpc --stdio \
    < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -e 'select(.id=="bad" and .error.code=="incompatible_version")' "$body" >/dev/null \
    || die 'version skew was not rejected'

  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  append_frame '{"version":1,"type":"request","id":"events","operationId":"operation-events","method":"incus.events"}' "$request"
  append_frame '{"version":1,"type":"cancel","id":"cancel","operationId":"operation-events"}' "$request"
  peer_ssh "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current" \
    "$remote_engine" rpc --stdio < "$request" > "$response"
  decode_frames "$response" "$body"
  jq -s -e 'any(.[]; .id=="cancel" and .result.cancelled=="operation-events") and
    any(.[]; .id=="events" and .operationId=="operation-events" and .error.code=="cancelled")' \
    "$body" >/dev/null || die 'live RPC cancellation failed'

  printf '\0\0\0\20broken' | peer_ssh "dev@$PEER_IP" -- \
    env SUBYARD_REPOSITORY_ROOT="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current" "$remote_engine" rpc --stdio >/dev/null 2>&1 || true
  : > "$request"
  append_frame '{"version":1,"type":"request","id":"negotiate","method":"rpc.negotiate"}' "$request"
  append_frame '{"version":1,"type":"request","id":"snapshot","method":"system.snapshot"}' "$request"
  peer_ssh "dev@$PEER_IP" -- env SUBYARD_REPOSITORY_ROOT="/home/dev/.cache/subyard-p0-peer-$TOKEN/runtime/current" \
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
  "$PEER_YARD_ENTRY" keys trust @peer --yes >/dev/null
  "$PEER_YARD_ENTRY" keys add p0-cross-owner --kind file --zone p0-cross-owner \
    --consumer staging-env --file "$expected" --yes >/dev/null
  credential="$("$PEER_YARD_ENTRY" keys list | awk -F '\t' '$8=="p0-cross-owner" {print $1}')"
  [ -n "$credential" ] || die 'cross-owner credential was not created'
  "$PEER_YARD_ENTRY" keys sync @peer --now --yes >/dev/null
  peer_ssh "dev@$PEER_IP" -- bash -lc \
    "$(printf '%q' 'yard keys materialize p0-cross-owner --yes')" >/dev/null
  source_hash="$(sha256sum "$expected" | awk '{print $1}')"
  remote_hash="$(peer_ssh "dev@$PEER_IP" -- sha256sum \
    "/tmp/subyard-p0-peer-$TOKEN/consumer/config/staging/p0-cross-owner.env" | awk '{print $1}')"
  [ "$source_hash" = "$remote_hash" ] || die 'cross-owner credential materialization differs'
  "$PEER_YARD_ENTRY" keys revoke "$credential" --yes >/dev/null
  "$PEER_YARD_ENTRY" keys sync @peer --now --yes >/dev/null
  peer_ssh "dev@$PEER_IP" -- bash -lc \
    "$(printf '%q' 'yard keys materialize p0-cross-owner --yes')" >/dev/null
  ! peer_ssh "dev@$PEER_IP" -- test -e \
    "/tmp/subyard-p0-peer-$TOKEN/consumer/config/staging/p0-cross-owner.env" \
    || die 'revoked cross-owner credential remains materialized'
  "$PEER_YARD_ENTRY" remote remove peer --yes >/dev/null
  printf 'ok: real cross-owner credential trust, sync and revoke\n'
}

peer_projects() {
  local source="$PEER_ROOT/project" remote_pwd
  local ssh_config="$HOME/.ssh/config"
  local include="Include $PEER_ROOT/home/.ssh/subyard-peer.config"
  [ "$SUBYARD_E2E_VM" = 1 ] || die 'remote project controller requires VM1'
  valid_ip "$PEER_IP" || die 'peer IP is invalid'
  install -d -m 0700 "$source"
  printf '%s\nbase\n' "$MARKER" > "$source/result.txt"
  [ ! -L "$HOME/.ssh" ] && [ ! -L "$ssh_config" ] \
    || die 'refusing symlinked SSH config paths'
  install -d -m 0700 "$HOME/.ssh"
  if [ ! -e "$PEER_CONFIG_STATE" ]; then
    if [ -e "$ssh_config" ]; then
      [ -f "$ssh_config" ] || die 'SSH config target is not a regular file'
      printf 'file\t%s\n' "$(stat -c '%a' "$ssh_config")" > "$PEER_CONFIG_STATE"
    else
      printf 'absent\n' > "$PEER_CONFIG_STATE"
    fi
  fi
  touch "$ssh_config"
  chmod 0600 "$ssh_config"
  grep -Fqx "$include" "$ssh_config" || printf '%s\n' "$include" >> "$ssh_config"
  "$PEER_YARD_ENTRY" remote add peer "dev@$PEER_IP" --yes >/dev/null
  "$PEER_YARD_ENTRY" -Y peer sync "$source" --yes >/dev/null
  remote_pwd="$("$PEER_YARD_ENTRY" -Y peer shell "$source" --yes -- pwd)"
  case "$remote_pwd" in /srv/workspaces/*/src) ;; *) die 'remote shell did not enter the synced project' ;; esac
  "$PEER_YARD_ENTRY" -Y peer shell "$source" --yes -- \
    sh -c 'printf "remote-mutated\n" >> result.txt'
  "$PEER_YARD_ENTRY" -Y peer shell "$source" --yes -- \
    grep -Fqx remote-mutated result.txt
  "$PEER_YARD_ENTRY" -Y peer remove "$source" --yes >/dev/null
  printf 'ok: release-installed remote add, sync and two project shells\n'
}

remove_peer_ssh_include() {
  local ssh_config="$HOME/.ssh/config"
  local include="Include $PEER_ROOT/home/.ssh/subyard-peer.config"
  local state mode extra temporary
  [ -e "$PEER_CONFIG_STATE" ] || return 0
  read -r state mode extra < "$PEER_CONFIG_STATE" \
    || die 'SSH config restore state is missing'
  [ -z "$extra" ] || die 'SSH config restore state is invalid'
  case "$state" in
    absent) [ -z "$mode" ] || die 'SSH config restore state is invalid' ;;
    file) [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die 'SSH config restore mode is invalid' ;;
    *) die 'SSH config restore state is invalid' ;;
  esac
  [ "$state" != absent ] || [ -e "$ssh_config" ] || return 0
  [ -f "$ssh_config" ] && [ ! -L "$ssh_config" ] \
    || die 'SSH config restore target is unavailable or unsafe'
  temporary="$(mktemp "$HOME/.ssh/.config.XXXXXX")"
  grep -vxF "$include" "$ssh_config" > "$temporary" || true
  chmod 0600 "$temporary"
  mv -f "$temporary" "$ssh_config"
  if [ "$state" = absent ] && [ ! -s "$ssh_config" ]; then
    find "$ssh_config" -delete
  elif [ "$state" = file ]; then
    chmod "$mode" "$ssh_config"
  fi
}

cleanup_peer_yard() {
  [ -e "$PEER_REAL_YARD_MARKER" ] || return 0
  [ "$(cat "$PEER_REAL_YARD_MARKER" 2>/dev/null)" = "$MARKER" ] \
    || die 'refusing to clean unmarked real peer yard'
  "$PEER_YARD_ENTRY" teardown --yes >/dev/null
  find "$PEER_REAL_YARD_MARKER" -delete
}

peer_clean() {
  remove_peer_authorization
  remove_peer_ssh_include
  cleanup_peer_yard
  remove_peer_wrapper
  cleanup_peer_snapshot_fixture
  cleanup_peer_incus
  clean_peer_data
  clean_tree "$PEER_ROOT" "$MARKER"
}

case "$MODE" in
  owner) owner ;;
  controller) controller ;;
  peer-prepare) peer_prepare ;;
  peer-prepare-resume) peer_prepare_finish ;;
  peer-info) peer_info ;;
  peer-authorize) peer_authorize ;;
  peer-probe) peer_probe ;;
  peer-yard-start) peer_yard_start ;;
  peer-projects) peer_projects ;;
  peer-rpc) peer_rpc ;;
  peer-credentials) peer_credentials ;;
  peer-clean) peer_clean ;;
  *) die 'unknown P0 guest mode' ;;
esac
