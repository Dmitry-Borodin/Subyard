#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TOKEN="${2:-}"
ARCHIVE="${3:-}"
ARCHIVE_SHA256="${4:-}"
SOURCE_REVISION="${5:-}"
MARKER="subyard-p0-source-$TOKEN"
OPERATOR="subyardp0$TOKEN"
OPERATOR_HOME="/home/$OPERATOR"
SOURCE_ROOT="$OPERATOR_HOME/src"
RELEASE_ROOT="/var/tmp/subyard-p0-source-release-$TOKEN"
SUDOERS="/etc/sudoers.d/subyard-p0-source-$TOKEN"
PROJECT="subyard-e2e-yard"
INSTANCE="yard-e2e-yard"
BASE_IMAGE="${P0_REAL_INCUS_CONTAINER_CACHE_ALIAS:-subyard-e2e-debian-13-cloud-container}"
VERSION_A="p0-source-a-$TOKEN"
VERSION_B="p0-source-b-$TOKEN"

die() { printf 'p0-source-upgrade: %s\n' "$*" >&2; exit 2; }
[[ "$TOKEN" =~ ^[0-9]+$ ]] || die 'allocation token must be numeric'
[ -n "${SUBYARD_E2E_VM:-}" ] && [ "$SUBYARD_E2E_VM" = 1 ] \
  || die 'run on allocated VM1 through dev/agent-e2e.sh'

operator_uid() { id -u "$OPERATOR"; }
operator_env() {
  local uid
  uid="$(operator_uid)"
  sudo -n /usr/sbin/runuser -u "$OPERATOR" -- bash -c '
    cd "$1"
    shift
    exec "$@"
  ' _ "$OPERATOR_HOME" env \
      HOME="$OPERATOR_HOME" USER="$OPERATOR" LOGNAME="$OPERATOR" SHELL=/bin/bash \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      "$@"
}
operator_no_go() {
  local uid fake="$OPERATOR_HOME/no-go"
  uid="$(operator_uid)"
  sudo -n unshare --mount --fork -- bash -c '
    set -e
    mount --make-rprivate /
    mount --bind "$1" /usr/bin/go
    shift
    cd "$2"
    exec /usr/sbin/runuser -u "$1" -- env \
      HOME="$2" USER="$1" LOGNAME="$1" SHELL=/bin/bash \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      XDG_RUNTIME_DIR="/run/user/$3" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$3/bus" \
      "${@:4}"
  ' _ "$fake" "$OPERATOR" "$OPERATOR_HOME" "$uid" "$@"
}
operator_yard() {
  operator_no_go "$OPERATOR_HOME/.local/bin/yard" "$@"
}

assert_fixture_project() {
  [ "$(incus project get "$PROJECT" user.subyard.p0-source 2>/dev/null)" = "$MARKER" ] \
    || die "refusing unmarked Incus project $PROJECT"
}

cleanup_fixture() {
  local fingerprint instance_marker='' type volume
  if incus project show "$PROJECT" >/dev/null 2>&1; then
    assert_fixture_project
    if id "$OPERATOR" >/dev/null 2>&1 \
      && sudo -n test -x "$OPERATOR_HOME/.local/bin/yard"; then
      operator_yard -Y e2e-yard teardown --yes >/dev/null 2>&1 \
        || printf '  [warn] fixture yard teardown failed; using marker-guarded cleanup\n' >&2
    fi
  fi
  if incus project show "$PROJECT" >/dev/null 2>&1; then
    assert_fixture_project
    if incus config show "$INSTANCE" --project "$PROJECT" >/dev/null 2>&1; then
      instance_marker="$(incus config get "$INSTANCE" user.subyard.managed \
        --project "$PROJECT" 2>/dev/null)"
      [ "$instance_marker" = true ] || die "refusing unmarked instance $PROJECT/$INSTANCE"
      incus delete "$INSTANCE" --project "$PROJECT" --force >/dev/null
    fi
    while IFS=, read -r type volume; do
      [ -n "$volume" ] || continue
      [ "$type" = custom ] || continue
      incus storage volume delete default "$volume" --project "$PROJECT" >/dev/null
    done < <(incus storage volume list default --project "$PROJECT" --format csv -c t,n)
    while IFS= read -r fingerprint; do
      [ -n "$fingerprint" ] || continue
      incus image delete "$fingerprint" --project "$PROJECT" >/dev/null
    done < <(incus image list --project "$PROJECT" --format csv -c f)
    incus project delete "$PROJECT" >/dev/null
    sudo -n find /srv/subyard-e2e-yard -depth -delete 2>/dev/null || true
  fi
  if id "$OPERATOR" >/dev/null 2>&1; then
    sudo -n loginctl disable-linger "$OPERATOR" >/dev/null 2>&1 || true
    sudo -n systemctl stop "user@$(operator_uid).service" >/dev/null 2>&1 || true
  fi
  sudo -n find "$SUDOERS" -delete 2>/dev/null || true
  if id "$OPERATOR" >/dev/null 2>&1; then
    sudo -n userdel -r "$OPERATOR" >/dev/null
  fi
  if [ -d "$RELEASE_ROOT" ]; then
    [ "$(cat "$RELEASE_ROOT/.subyard-p0-marker" 2>/dev/null)" = "$MARKER" ] \
      || die "refusing unmarked release root $RELEASE_ROOT"
    sudo -n find "$RELEASE_ROOT" -depth -delete
  fi
}

prepare_operator() {
  local sudoers_tmp uid
  ! id "$OPERATOR" >/dev/null 2>&1 || die "fixture user $OPERATOR already exists"
  [ ! -e "$RELEASE_ROOT" ] || die "fixture release root already exists"
  sudo -n useradd --create-home --shell /bin/bash "$OPERATOR"
  sudo -n usermod -aG incus-admin "$OPERATOR"
  sudoers_tmp="$(mktemp /tmp/subyard-p0-sudoers.XXXXXX)"
  printf '%s ALL=(root) NOPASSWD: ALL\n' "$OPERATOR" > "$sudoers_tmp"
  sudo -n install -o root -g root -m 0440 "$sudoers_tmp" "$SUDOERS"
  find "$sudoers_tmp" -delete
  sudo -n loginctl enable-linger "$OPERATOR"
  uid="$(operator_uid)"
  sudo -n systemctl start "user@$uid.service"
  for _ in $(seq 1 30); do
    sudo -n test -S "/run/user/$uid/bus" && break
    sleep 1
  done
  sudo -n test -S "/run/user/$uid/bus" || die 'fixture user bus did not start'
  operator_env install -d -m 0700 "$SOURCE_ROOT"
  sudo -n install -o "$OPERATOR" -g "$OPERATOR" -m 0600 \
    "$ARCHIVE" "$OPERATOR_HOME/source.tar.gz"
  operator_env tar -xzf "$OPERATOR_HOME/source.tar.gz" -C "$SOURCE_ROOT"
  operator_env find "$OPERATOR_HOME/source.tar.gz" -delete
  operator_env install -d -m 0700 \
    "$SOURCE_ROOT/private/yards" "$SOURCE_ROOT/private/agents/codex" \
    "$SOURCE_ROOT/config/profiles/openclaw" "$SOURCE_ROOT/config/staging" \
    "$SOURCE_ROOT/config/qa-pool" \
    "$OPERATOR_HOME/.local/bin"
  operator_env bash -c 'printf "%s" "$2" > "$1"' _ "$SOURCE_ROOT/private/config.env" \
    $'DEV_SUDO=1\nAGENT_codex_RULES="$SUBYARD_CONFIG_DIR/../private/agents/codex/repo.rules"\n'
  operator_env bash -c \
    'printf "YARD_TEMPLATE=e2e-vms\nSSH_PORT=2223\nDEV_UID=1001\nBASE_IMAGE=%s\nBASE_IMAGE_FALLBACK=%s\n" "$2" "$2" > "$1"' \
    _ "$SOURCE_ROOT/private/yards/e2e-yard.env" "$BASE_IMAGE"
  operator_env bash -c 'printf "source-upgrade-fixture\n" > "$1"' _ \
    "$SOURCE_ROOT/private/agents/codex/repo.rules"
  operator_env bash -c 'printf "PROFILE_TOKEN=source-profile-fixture\n" > "$1"' _ \
    "$SOURCE_ROOT/config/profiles/openclaw/profile.env"
  operator_env bash -c \
    'printf "PROFILE=openclaw\n" > "$1"; printf "STAGING_TOKEN=source-staging-fixture\n" > "$2"' _ \
    "$SOURCE_ROOT/config/staging/canonical.conf" "$SOURCE_ROOT/config/staging/canonical.env"
  operator_env bash -c \
    'printf "source-fingerprint\n" > "$1"; printf "CLOUD_PORT=3210\n" > "$2"; printf "QA_SECRET=source-qa-fixture\n" > "$3"; printf "{\"fixture\":true}\n" > "$4"; printf "retain-me\n" > "$5"' _ \
    "$SOURCE_ROOT/config/prod-fingerprints" \
    "$SOURCE_ROOT/config/qa-pool/broker.conf" \
    "$SOURCE_ROOT/config/qa-pool/secrets.env" \
    "$SOURCE_ROOT/config/qa-pool/pool.jsonl" \
    "$SOURCE_ROOT/config/qa-pool/operator-note.local"
  operator_env chmod 0600 \
    "$SOURCE_ROOT/private/config.env" "$SOURCE_ROOT/private/yards/e2e-yard.env" \
    "$SOURCE_ROOT/private/agents/codex/repo.rules" \
    "$SOURCE_ROOT/config/profiles/openclaw/profile.env" \
    "$SOURCE_ROOT/config/staging/canonical.conf" "$SOURCE_ROOT/config/staging/canonical.env" \
    "$SOURCE_ROOT/config/prod-fingerprints" \
    "$SOURCE_ROOT/config/qa-pool/broker.conf" \
    "$SOURCE_ROOT/config/qa-pool/secrets.env" \
    "$SOURCE_ROOT/config/qa-pool/pool.jsonl" \
    "$SOURCE_ROOT/config/qa-pool/operator-note.local"
  operator_env env YARD_BUILD_VERSION="source-$SOURCE_REVISION" \
    "$SOURCE_ROOT/scripts/build-engine.sh" --force
  operator_env ln -s "$SOURCE_ROOT/bin/yard" "$OPERATOR_HOME/.local/bin/yard"
  operator_env ln -s "$SOURCE_ROOT/bin/yard" "$OPERATOR_HOME/.local/bin/sy"
  operator_env bash -c \
    'printf "# Subyard CLI\nexport PATH=\"%s/.local/bin:\\$PATH\"\n# Subyard CLI completion\n[ -f \"%s/completions/yard.bash\" ] && source \"%s/completions/yard.bash\"\n" "$1" "$2" "$2" > "$1/.bashrc"; printf "# Subyard CLI login PATH\nexport PATH=\"%s/.local/bin:\\$PATH\"\n" "$1" > "$1/.profile"' \
    _ "$OPERATOR_HOME" "$SOURCE_ROOT" "$OPERATOR_HOME"
  operator_env bash -c \
    'printf "#!/bin/sh\nprintf invoked > \"%s/go-invoked\"\nexit 127\n" "$1" > "$1/no-go"; chmod 0700 "$1/no-go"' \
    _ "$OPERATOR_HOME"
}

seed_previous_migration_inputs() {
  operator_env install -d -m 0700 \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/codex" \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/claude"
  operator_env cp "$SOURCE_ROOT/private/config.env" "$OPERATOR_HOME/.subyard/config.env"
  operator_env cp "$SOURCE_ROOT/private/agents/codex/repo.rules" \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/codex/repo.rules"
  operator_env bash -c 'printf "{\"fixture\":true}\n" > "$1"' _ \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/claude/settings.json"
  operator_env chmod 0600 "$OPERATOR_HOME/.subyard/config.env" \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/codex/repo.rules" \
    "$OPERATOR_HOME/.subyard/operator-overlay/private/agents/claude/settings.json"
}

package_candidates() {
  local fstype
  install -d -m 0700 "$RELEASE_ROOT/a" "$RELEASE_ROOT/b"
  fstype="$(findmnt -n -o FSTYPE --target "$RELEASE_ROOT")" \
    || die "cannot identify release fixture filesystem"
  case "$fstype" in
    tmpfs | ramfs) die "release fixture must survive reboot" ;;
  esac
  printf '%s\n' "$MARKER" > "$RELEASE_ROOT/.subyard-p0-marker"
  printf '%s\n' "$SOURCE_REVISION" > "$RELEASE_ROOT/source-revision"
  "$ROOT/dev/package-engine.sh" --output-dir "$RELEASE_ROOT/a" --version "$VERSION_A" >/dev/null
  "$ROOT/dev/package-engine.sh" --output-dir "$RELEASE_ROOT/b" --version "$VERSION_B" >/dev/null
  chmod -R a+rX "$RELEASE_ROOT"
}

bootstrap_candidate() {
  local release="$1" version="$2"
  operator_no_go env \
    YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION="$version" \
    "$release/subyard-install.sh" --yes
  operator_env test ! -e "$OPERATOR_HOME/go-invoked" \
    || die 'standalone installer invoked Go'
}

verify_migration() {
  local runtime="$OPERATOR_HOME/.subyard/runtime/current/bin/yard"
  [ "$(operator_env readlink "$OPERATOR_HOME/.local/bin/yard")" = "$runtime" ] \
    && [ "$(operator_env readlink "$OPERATOR_HOME/.local/bin/sy")" = "$runtime" ] \
    || die 'source entrypoints did not switch to the immutable runtime'
  operator_env test -x "$SOURCE_ROOT/.build/yard" \
    || die 'source checkout was changed or removed'
  operator_env cmp "$SOURCE_ROOT/private/config.env" "$OPERATOR_HOME/.config/subyard/config.env" \
    || die 'machine config was not migrated'
  operator_env bash -c \
    'sed "s/^YARD_TEMPLATE=e2e-vms$/YARD_TEMPLATE=test-vms/" "$1" | cmp - "$2"' _ \
    "$SOURCE_ROOT/private/yards/e2e-yard.env" \
    "$OPERATOR_HOME/.config/subyard/yards/e2e-yard/config.env" \
    || die 'named yard was not migrated to the canonical template'
  operator_env cmp "$SOURCE_ROOT/private/agents/codex/repo.rules" \
    "$OPERATOR_HOME/.config/subyard/overrides/host/agents/codex/repo.rules" \
    || die 'private agent asset was not migrated'
  operator_env test -f \
    "$OPERATOR_HOME/.config/subyard/overrides/host/agents/claude/settings.json" \
    || die 'transitional operator overlay was not migrated'
  operator_env cmp "$SOURCE_ROOT/config/profiles/openclaw/profile.env" \
    "$OPERATOR_HOME/.config/subyard/secrets/profiles/openclaw/profile.env" \
    || die 'profile secret was not migrated'
  operator_env cmp "$SOURCE_ROOT/config/staging/canonical.conf" \
    "$OPERATOR_HOME/.config/subyard/overrides/host/staging/canonical.conf" \
    || die 'staging config was not migrated'
  operator_env cmp "$SOURCE_ROOT/config/staging/canonical.env" \
    "$OPERATOR_HOME/.config/subyard/secrets/legacy/staging/canonical.env" \
    || die 'legacy staging secret was not retained'
  operator_env cmp "$SOURCE_ROOT/config/qa-pool/operator-note.local" \
    "$OPERATOR_HOME/.config/subyard/secrets/legacy/unclassified/qa-pool/operator-note.local" \
    || die 'unclassified ignored input was not retained'
  operator_env test ! -e "$OPERATOR_HOME/.subyard/config.env" \
    || die 'legacy machine config remained under the data home'
  operator_env test ! -e "$OPERATOR_HOME/.subyard/operator-overlay" \
    || die 'legacy operator overlay remained under the data home'
  operator_env test -x "$OPERATOR_HOME/.subyard/recovery/pre-go-source/restore.sh" \
    || die 'guarded source recovery was not retained'
}

verify_config_workflow() {
  local paths host_hash guest_hash status_output status_rc
  paths="$(operator_yard -Y e2e-yard config paths)"
  grep -Fq "config-root: $OPERATOR_HOME/.config/subyard" <<<"$paths" \
    || die 'config paths did not report the persistent operator root'
  grep -Fq "$OPERATOR_HOME/.config/subyard/overrides/host/agents/codex/repo.rules (host)" \
    <<<"$paths" || die 'config paths did not resolve the migrated Codex asset'
  ! grep -Fq 'source-staging-fixture' <<<"$paths" \
    || die 'config paths printed a secret value'
  set +e
  status_output="$(operator_yard -Y e2e-yard config status --all-local 2>&1)"
  status_rc=$?
  set -e
  printf '%s\n' "$status_output"
  if [ "$status_rc" -ne 0 ]; then
    [ "$status_rc" -eq 1 ] \
      && grep -Fq 'yard e2e-yard: drift' <<<"$status_output" \
      && grep -Fq 'config status: agent config drift in yards: e2e-yard' <<<"$status_output" \
      || die 'config status failed for a reason other than expected agent drift'
  fi
  ! grep -Eq 'source-(staging|qa|profile)-fixture' <<<"$status_output" \
    || die 'config status printed a secret value'
  operator_yard -Y e2e-yard config apply --all-local --yes
  operator_yard -Y e2e-yard config status --all-local
  host_hash="$(sudo -n sha256sum \
    "$OPERATOR_HOME/.config/subyard/overrides/host/agents/codex/repo.rules" | awk '{print $1}')"
  guest_hash="$(incus exec "$INSTANCE" --project "$PROJECT" --user 1001 --group 1001 -- \
    sha256sum /home/dev/.codex/rules/repo.rules | awk '{print $1}')"
  [ "$host_hash" = "$guest_hash" ] || die 'migrated Codex rules were not applied to the yard'
}

verify_without_source_checkout() {
  local unavailable="$OPERATOR_HOME/src.unavailable"
  operator_env mv "$SOURCE_ROOT" "$unavailable"
  if ! operator_yard -Y e2e-yard config paths >/dev/null \
    || ! operator_yard -Y e2e-yard config status --all-local \
    || ! operator_yard -Y e2e-yard check; then
    operator_env mv "$unavailable" "$SOURCE_ROOT"
    die 'installed runtime still depends on the source checkout'
  fi
  operator_env mv "$unavailable" "$SOURCE_ROOT"
}

wait_for_running_yard() {
  local _ state=''
  for _ in $(seq 1 60); do
    state="$(incus list "$INSTANCE" --project "$PROJECT" -f csv -c s 2>/dev/null)" \
      || state=''
    [ "$state" = RUNNING ] && return 0
    sleep 1
  done
  sudo -n systemctl --no-pager --full status subyard-power-reconcile.service >&2 || true
  sudo -n journalctl -u subyard-power-reconcile.service -b --no-pager -n 120 >&2 || true
  return 1
}

prepare_project() {
  incus project show "$PROJECT" >/dev/null 2>&1 \
    && die "refusing to replace existing project $PROJECT"
  incus image info "$BASE_IMAGE" --project default >/dev/null 2>&1 \
    || die "test base image $BASE_IMAGE is unavailable"
  incus project create "$PROJECT" \
    -c features.images=false -c user.subyard.p0-source="$MARKER" >/dev/null
}

run_incus_installer() {
  (
    # shellcheck source=tests/helpers/test-context.sh
    . "$ROOT/tests/helpers/test-context.sh"
    setup_test_context "$HOME/.subyard/p0-source-bootstrap-$TOKEN"
    export SUBYARD_USER
    SUBYARD_USER="$(id -un)"
    export SUBYARD_OPERATOR_HOME="$HOME"
    export SUBYARD_CONFIG_DIR="$ROOT/config"
    export SUBYARD_CONFIG_HOME="$HOME/.config/subyard"
    export SUBYARD_HOME="$HOME/.subyard"
    export STORAGE_PATH="$SUBYARD_HOME/incus/storage"
    export HOST_BASE="$SUBYARD_HOME/p0-source-host-data-$TOKEN"
    export RESTRICTED_DISK_PATHS="$HOST_BASE"
    set -a
    # shellcheck source=config/host.env
    . "$ROOT/config/host.env"
    set +a
    bash "$ROOT/scripts/01-install-incus.sh" "$@"
  )
}

prepare() {
  [[ "$ARCHIVE" =~ ^/tmp/subyard-p0-source-[0-9]+\.tar\.gz$ ]] \
    || die 'source archive path is invalid'
  [[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'source archive hash is invalid'
  [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || die 'source revision is invalid'
  [ "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" = "$ARCHIVE_SHA256" ] \
    || die 'source archive checksum mismatch'
  command -v go >/dev/null 2>&1 || die 'fixture preparation needs Go'
  command -v unshare >/dev/null 2>&1 || die 'unshare is required'
  if ! incus info >/dev/null 2>&1 \
    || ! incus storage show default --project default >/dev/null 2>&1 \
    || ! incus network show incusbr0 --project default >/dev/null 2>&1; then
    run_incus_installer --yes --zabbly
  fi
  if ! incus image info "$BASE_IMAGE" --project default >/dev/null 2>&1; then
    bash "$ROOT/dev/e2e/p0-real-incus.sh"
  fi
  cleanup_fixture
  prepare_operator
  package_candidates
  prepare_project

  [ "$(operator_no_go "$SOURCE_ROOT/bin/yard" --version)" = "yard source-$SOURCE_REVISION" ] \
    || die 'exact source-linked CLI is not operational without Go'
  operator_yard -Y e2e-yard init --yes
  operator_yard -Y e2e-yard start --yes
  operator_yard -Y e2e-yard check
  seed_previous_migration_inputs

  bootstrap_candidate "$RELEASE_ROOT/a" "$VERSION_A"
  verify_migration
  [ "$(operator_yard --version)" = "yard $VERSION_A" ] \
    || die 'first candidate runtime is not active'
  bootstrap_candidate "$RELEASE_ROOT/a" "$VERSION_A"
  [ "$(operator_env grep -Fc '# Subyard CLI completion' "$OPERATOR_HOME/.bashrc")" = 1 ] \
    || die 'repeated bootstrap duplicated shell integration'
  operator_yard -Y e2e-yard init --yes
  operator_yard -Y e2e-yard check
  operator_yard -Y e2e-yard init --yes
  verify_config_workflow
  verify_without_source_checkout

  operator_no_go env YARD_RELEASE_BASE_URL="file://$RELEASE_ROOT/b" \
    "$OPERATOR_HOME/.local/bin/yard" update --version "$VERSION_B" --yes
  [ "$(operator_yard --version)" = "yard $VERSION_B" ] \
    || die 'candidate update did not activate the new runtime'
  operator_yard update --rollback --yes
  [ "$(operator_yard --version)" = "yard $VERSION_A" ] \
    || die 'candidate rollback did not restore the previous runtime'
  verify_config_workflow
  operator_no_go env YARD_RELEASE_BASE_URL="file://$RELEASE_ROOT/b" \
    "$OPERATOR_HOME/.local/bin/yard" update --version "$VERSION_B" --yes
  operator_yard -Y e2e-yard start --yes
  [ "$(incus config get "$INSTANCE" user.subyard.desired_power --project "$PROJECT")" = running ] \
    || die 'yard desired power is not persisted before reboot'
  operator_env test ! -e "$OPERATOR_HOME/go-invoked" \
    || die 'production operator cycle invoked Go'
  printf 'ok: exact source-linked %s upgraded without Go and is ready for reboot\n' \
    "$SOURCE_REVISION"
}

finish() {
  SOURCE_REVISION="$(cat "$RELEASE_ROOT/source-revision" 2>/dev/null)" \
    || die 'source revision metadata disappeared after reboot'
  [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] \
    || die 'source revision metadata is invalid'
  id "$OPERATOR" >/dev/null 2>&1 || die 'fixture operator disappeared after reboot'
  assert_fixture_project
  [ "$(operator_yard --version)" = "yard $VERSION_B" ] \
    || die 'runtime entrypoint did not survive reboot'
  wait_for_running_yard || die 'boot reconciler did not restore the running yard'
  [ "$(incus config get "$INSTANCE" user.subyard.desired_power --project "$PROJECT")" = running ] \
    || die 'desired power changed across reboot'
  operator_yard -Y e2e-yard status >/dev/null
  operator_yard -Y e2e-yard check
  operator_yard -Y e2e-yard init --yes
  verify_config_workflow

  operator_no_go "$OPERATOR_HOME/.subyard/recovery/pre-go-source/restore.sh" >/dev/null
  [ "$(operator_env readlink -f "$OPERATOR_HOME/.local/bin/yard")" = "$SOURCE_ROOT/bin/yard" ] \
    || die 'guarded recovery did not restore the source entrypoint'
  [ "$(operator_no_go "$SOURCE_ROOT/bin/yard" --version)" = "yard source-$SOURCE_REVISION" ] \
    || die 'recovered source entrypoint is not operational without Go'
  bootstrap_candidate "$RELEASE_ROOT/b" "$VERSION_B"
  [ "$(operator_yard --version)" = "yard $VERSION_B" ] \
    || die 'standalone installer could not re-enter the runtime after recovery'
  verify_migration
  operator_yard -Y e2e-yard init --yes
  operator_yard -Y e2e-yard check
  verify_config_workflow
  operator_yard -Y e2e-yard teardown --yes
  ! incus project show "$PROJECT" >/dev/null 2>&1 \
    || die 'upgraded yard remains after teardown'
  operator_env test ! -e "$OPERATOR_HOME/go-invoked" \
    || die 'post-reboot operator cycle invoked Go'
  cleanup_fixture
  printf 'ok: source upgrade survived reboot, recovery and repeat installation\n'
}

case "$MODE" in
  prepare) prepare ;;
  finish) finish ;;
  clean) cleanup_fixture ;;
  *) die 'expected prepare, finish or clean' ;;
esac
