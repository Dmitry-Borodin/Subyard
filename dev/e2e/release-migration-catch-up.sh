#!/usr/bin/env bash
# Real released-runtime catch-up acceptance on an allocated disposable VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-auto}"
VM="${SUBYARD_E2E_VM:-}"
OLD_VERSION=0.3.1
MISSED_VERSION=0.4.0
OLD_INSTALLER_SHA256=3d578aa7200a55973d5e638c249511af949c461a29ee0d148af77d3514449371
CANDIDATE_VERSION="0.4.1-catchup-vm${VM:-unknown}"
STATE_ROOT="/var/tmp/subyard-release-catchup-vm${VM:-unknown}"
MARKER="subyard-release-catchup-vm${VM:-unknown}"
OPERATOR="subyardmigrate${VM:-x}"
OPERATOR_HOME="$STATE_ROOT/operator-home"
CANDIDATE_RELEASE="$STATE_ROOT/candidate"
INSTALLER="$STATE_ROOT/subyard-install-0.3.1.sh"
SUDOERS="/etc/sudoers.d/$MARKER"
CONSUMER_PROJECT=subyard
CONSUMER_INSTANCE=yard
LEGACY_PROJECT=subyard-e2e-yard
LEGACY_INSTANCE='yard-e2e-yard'
CURRENT_PROJECT=subyard-test-yard
CURRENT_INSTANCE='yard-test-yard'
IMAGE_ALIAS=subyard-e2e-debian-13-cloud-container
PLATFORM_ROOT="$HOME/.cache/subyard-release-catchup-platform-vm${VM:-unknown}"
PLATFORM_STORAGE="$PLATFORM_ROOT/data/incus/storage"
PLATFORM_OWNED=0
CLEANUP_ARMED=0

die() { printf 'release-migration-catch-up: %s\n' "$*" >&2; exit 2; }
info() { printf '  [ .. ] %s\n' "$*"; }
ok() { printf '  [ ok ] %s\n' "$*"; }
host_incus() { sudo -n incus "$@" </dev/null; }
operator_uid() { id -u "$OPERATOR"; }
operator_env() {
  local uid
  uid="$(operator_uid)"
  sudo -n /usr/sbin/runuser -u "$OPERATOR" -- env \
    HOME="$OPERATOR_HOME" USER="$OPERATOR" LOGNAME="$OPERATOR" SHELL=/bin/bash \
    PATH="$OPERATOR_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@"
}
operator_yard() { operator_env "$OPERATOR_HOME/.local/bin/yard" "$@"; }
operator_test_vms_status() {
  operator_yard -Y test-yard test-vms status 2>&1
}

ensure_host_incus() {
  local source=''
  if command -v incus >/dev/null 2>&1 \
    && sudo -n incus info >/dev/null 2>&1 \
    && sudo -n incus storage show default --project default >/dev/null 2>&1; then
    source="$(sudo -n incus storage get default source --project default)"
    if [ "$source" = "$PLATFORM_STORAGE" ]; then
      [ -d "$PLATFORM_ROOT" ] && [ ! -L "$PLATFORM_ROOT" ] \
        && [ "$(cat "$PLATFORM_ROOT/.marker" 2>/dev/null)" = "$MARKER" ] \
        || die "refusing unmarked Incus platform root $PLATFORM_ROOT"
      sudo -n test -d "$PLATFORM_STORAGE" \
        || die "owned Incus storage source disappeared: $PLATFORM_STORAGE"
      PLATFORM_OWNED=1
    fi
    sudo -n incus network show incusbr0 --project default >/dev/null 2>&1 \
      && return
  fi
  if [ -e "$PLATFORM_ROOT" ]; then
    [ -d "$PLATFORM_ROOT" ] && [ ! -L "$PLATFORM_ROOT" ] \
      && [ "$(cat "$PLATFORM_ROOT/.marker" 2>/dev/null)" = "$MARKER" ] \
      || die "refusing unmarked Incus platform root $PLATFORM_ROOT"
  else
    install -d -m 0700 "$PLATFORM_ROOT"
    printf '%s\n' "$MARKER" > "$PLATFORM_ROOT/.marker"
  fi
  PLATFORM_OWNED=1
  info "installing and initializing Incus on clean VM$VM"
  (
    # shellcheck source=tests/helpers/test-context.sh
    . "$ROOT/tests/helpers/test-context.sh"
    setup_test_context "$PLATFORM_ROOT/bootstrap"
    export SUBYARD_USER
    SUBYARD_USER="$(id -un)"
    export SUBYARD_OPERATOR_HOME="$HOME"
    export SUBYARD_CONFIG_DIR="$ROOT/config"
    export SUBYARD_CONFIG_HOME="$PLATFORM_ROOT/config"
    export SUBYARD_HOME="$PLATFORM_ROOT/data"
    export STORAGE_PATH="$SUBYARD_HOME/incus/storage"
    export HOST_BASE="$SUBYARD_HOME/host-data"
    export RESTRICTED_DISK_PATHS="$HOST_BASE"
    bash "$ROOT/scripts/01-install-incus.sh" --yes --zabbly
  )
  command -v incus >/dev/null 2>&1 \
    && sudo -n incus info >/dev/null \
    && sudo -n incus storage show default --project default >/dev/null \
    && sudo -n incus network show incusbr0 --project default >/dev/null \
    || die "Incus bootstrap did not converge"
  ok "Incus owner API is ready on VM$VM"
}

cleanup_owned_host_incus() {
  local device fingerprint source
  [ "$PLATFORM_OWNED" = 1 ] || return 0
  [ -d "$PLATFORM_ROOT" ] && [ ! -L "$PLATFORM_ROOT" ] \
    && [ "$(cat "$PLATFORM_ROOT/.marker" 2>/dev/null)" = "$MARKER" ] \
    || {
      printf 'release-migration-catch-up: refusing unmarked platform cleanup %s\n' \
        "$PLATFORM_ROOT" >&2
      return 1
    }
  host_incus storage show default --project default >/dev/null 2>&1 || return 0
  source="$(host_incus storage get default source --project default)"
  [ "$source" = "$PLATFORM_STORAGE" ] || {
    printf 'release-migration-catch-up: refusing foreign storage cleanup %s\n' \
      "$source" >&2
    return 1
  }
  [ -z "$(host_incus list --all-projects --format csv -c n)" ] || {
    printf 'release-migration-catch-up: owned platform still has instances\n' >&2
    return 1
  }
  while IFS= read -r fingerprint; do
    [ -n "$fingerprint" ] || continue
    host_incus image delete "$fingerprint" --project default >/dev/null || return
  done < <(host_incus image list --project default --format csv -c f)
  for device in eth0 root; do
    if host_incus profile device list default --project default 2>/dev/null \
      | grep -qx "$device"; then
      host_incus profile device remove default "$device" --project default >/dev/null \
        || return
    fi
  done
  if host_incus network show incusbr0 --project default >/dev/null 2>&1; then
    host_incus network delete incusbr0 --project default >/dev/null || return
  fi
  host_incus storage delete default --project default >/dev/null || return
  sudo -n find "$PLATFORM_ROOT" -depth -delete || return
}

assert_state_root() {
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    && [ "$(cat "$STATE_ROOT/.marker" 2>/dev/null)" = "$MARKER" ] \
    || die "refusing unmarked state root $STATE_ROOT"
}

mark_outer_project_for_cleanup() {
  local project="$1" instance="$2" yard="$3" registration
  host_incus project show "$project" >/dev/null 2>&1 || return 0
  if [ "$(host_incus project get "$project" user.subyard.release-catchup 2>/dev/null)" = \
    "$MARKER" ]; then
    return 0
  fi
  registration="$OPERATOR_HOME/.config/subyard/yards/$yard/config.env"
  [ -f "$registration" ] && grep -qx 'YARD_TEMPLATE=test-vms' "$registration" \
    || die "refusing unregistered outer project $project"
  [ "$(host_incus config get "$instance" user.subyard.managed \
    --project "$project" 2>/dev/null)" = true ] \
    || die "refusing foreign outer instance $project/$instance"
  host_incus project set "$project" user.subyard.release-catchup="$MARKER"
}

delete_marked_project() {
  local project="$1" instance="$2" volume type
  host_incus project show "$project" >/dev/null 2>&1 || return 0
  [ "$(host_incus project get "$project" user.subyard.release-catchup 2>/dev/null)" = \
    "$MARKER" ] \
    || die "refusing unmarked project $project"
  if host_incus config show "$instance" --project "$project" >/dev/null 2>&1; then
    [ "$(host_incus config get "$instance" user.subyard.managed \
      --project "$project" 2>/dev/null)" = true ] \
      || die "refusing foreign instance $project/$instance"
    host_incus delete "$instance" --project "$project" --force >/dev/null
  fi
  while IFS=, read -r type volume; do
    [ "$type" = custom ] && [ -n "$volume" ] || continue
    host_incus storage volume delete default "$volume" --project "$project" >/dev/null
  done < <(host_incus storage volume list default --project "$project" --format csv -c t,n)
  [ -z "$(host_incus list --project "$project" --format csv -c n)" ] \
    || die "unexpected instance remains in $project"
  host_incus project delete "$project" >/dev/null
}

cleanup() {
  local rc=$? cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  [ "$CLEANUP_ARMED" = 1 ] || exit "$rc"
  if id "$OPERATOR" >/dev/null 2>&1; then
    if host_incus project show "$CURRENT_PROJECT" >/dev/null 2>&1; then
      mark_outer_project_for_cleanup "$CURRENT_PROJECT" "$CURRENT_INSTANCE" test-yard
      operator_yard -Y test-yard teardown --yes >/dev/null 2>&1 || true
    elif host_incus project show "$LEGACY_PROJECT" >/dev/null 2>&1; then
      mark_outer_project_for_cleanup "$LEGACY_PROJECT" "$LEGACY_INSTANCE" e2e-yard
      operator_yard -Y e2e-yard teardown --yes >/dev/null 2>&1 || true
    fi
  fi
  delete_marked_project "$CURRENT_PROJECT" "$CURRENT_INSTANCE"
  delete_marked_project "$LEGACY_PROJECT" "$LEGACY_INSTANCE"
  delete_marked_project "$CONSUMER_PROJECT" "$CONSUMER_INSTANCE"
  cleanup_owned_host_incus || cleanup_failed=1
  sudo -n find /srv/subyard-test-yard -depth -delete 2>/dev/null || true
  sudo -n find /srv/subyard-e2e-yard -depth -delete 2>/dev/null || true
  sudo -n find /srv/subyard -depth -delete 2>/dev/null || true
  if id "$OPERATOR" >/dev/null 2>&1; then
    sudo -n loginctl disable-linger "$OPERATOR" >/dev/null 2>&1 || true
    sudo -n systemctl stop "user@$(operator_uid).service" >/dev/null 2>&1 || true
    sudo -n userdel -r "$OPERATOR" >/dev/null 2>&1 || true
  fi
  sudo -n find "$SUDOERS" -delete 2>/dev/null || true
  if [ -d "$STATE_ROOT" ]; then
    assert_state_root
    find "$STATE_ROOT" -depth -delete
  fi
  [ "$cleanup_failed" = 0 ] || rc=3
  exit "$rc"
}
trap cleanup EXIT INT TERM

prepare_host() {
  [ "$VM" = 1 ] || [ "$VM" = 2 ] \
    || die "run through dev/agent-e2e.sh on VM1 or VM2"
  case "$MODE" in
    auto) [ "$VM" = 1 ] && MODE=direct || MODE=missed ;;
    direct) [ "$VM" = 1 ] || die "the direct lane is pinned to VM1" ;;
    missed) [ "$VM" = 2 ] || die "the missed lane is pinned to VM2" ;;
    *) die "expected auto, direct or missed" ;;
  esac
  for command in curl git go jq ssh-keygen sudo tar; do
    command -v "$command" >/dev/null 2>&1 || die "$command is required"
  done
  sudo -n true || die "passwordless sudo is required"
  ensure_host_incus
  host_incus info >/dev/null || die "initialized Incus is required"
  host_incus storage show default --project default >/dev/null \
    || die "Incus default storage is unavailable"
  host_incus network show incusbr0 --project default >/dev/null \
    || die "Incus incusbr0 is unavailable"
  for project in \
    "$CONSUMER_PROJECT" "$LEGACY_PROJECT" "$CURRENT_PROJECT"; do
    ! host_incus project show "$project" >/dev/null 2>&1 \
      || die "fixture target project already exists: $project"
  done
  [ ! -e "$STATE_ROOT" ] || die "fixture state already exists: $STATE_ROOT"
  install -d -m 0711 "$STATE_ROOT"
  printf '%s\n' "$MARKER" > "$STATE_ROOT/.marker"
  CLEANUP_ARMED=1
}

prepare_operator() {
  local base_image sudoers_tmp uid
  ! id "$OPERATOR" >/dev/null 2>&1 || die "fixture user $OPERATOR already exists"
  sudo -n useradd --create-home --home-dir "$OPERATOR_HOME" --shell /bin/bash "$OPERATOR"
  sudo -n usermod -aG incus-admin "$OPERATOR"
  sudoers_tmp="$(mktemp /tmp/subyard-release-catchup-sudoers.XXXXXX)"
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
  sudo -n test -S "/run/user/$uid/bus" || die "fixture user bus is unavailable"
  operator_env install -d -m 0700 \
    "$OPERATOR_HOME/.config/subyard/yards/e2e-yard" \
    "$OPERATOR_HOME/.local/bin"
  operator_env bash -c 'printf "%s" "$2" > "$1"' _ \
    "$OPERATOR_HOME/.config/subyard/config.env" \
    $'AGENTS=none\n'
  base_image="$IMAGE_ALIAS"
  if ! host_incus image info "$base_image" --project default >/dev/null 2>&1; then
    base_image=images:debian/13
  fi
  operator_env bash -c 'printf "%s" "$2" > "$1"' _ \
    "$OPERATOR_HOME/.config/subyard/yards/e2e-yard/config.env" \
    "$(printf '%s\n' \
      'YARD_TEMPLATE=test-vms' \
      'SSH_PORT=2223' \
      'AGENTS=none' \
      'DEV_UID=1001' \
      'E2E_VM_CPU=1' \
      'E2E_VM_MEMORY=1GiB' \
      'E2E_VM_DISK=10GiB' \
      "BASE_IMAGE=$base_image" \
      "BASE_IMAGE_FALLBACK=$base_image")"
  operator_env chmod 0600 \
    "$OPERATOR_HOME/.config/subyard/config.env" \
    "$OPERATOR_HOME/.config/subyard/yards/e2e-yard/config.env"
}

prepare_candidate() {
  info "packaging exact local candidate $CANDIDATE_VERSION"
  "$ROOT/dev/package-engine.sh" \
    --output-dir "$CANDIDATE_RELEASE" \
    --version "$CANDIDATE_VERSION" >/dev/null
  chmod -R a+rX "$CANDIDATE_RELEASE"
  [ -f "$CANDIDATE_RELEASE/subyard-install.sh" ] \
    || die "candidate installer is unavailable"
}

install_old_runtime() {
  info "installing published yard $OLD_VERSION"
  curl -fsSL --proto '=https' --tlsv1.2 \
    "https://github.com/Subyard/Subyard/releases/download/v$OLD_VERSION/subyard-install.sh" \
    -o "$INSTALLER"
  [ "$(sha256sum "$INSTALLER" | awk '{print $1}')" = "$OLD_INSTALLER_SHA256" ] \
    || die "published $OLD_VERSION installer checksum changed"
  chmod 0755 "$INSTALLER"
  operator_env env YARD_RELEASE_VERSION="$OLD_VERSION" \
    "$INSTALLER" --version "$OLD_VERSION" --yes
  [ "$(operator_yard --version)" = "yard $OLD_VERSION" ] \
    || die "published $OLD_VERSION runtime is not active"
}

prepare_consumer() {
  local image="$IMAGE_ALIAS"
  if ! host_incus image info "$image" --project default >/dev/null 2>&1; then
    image=images:debian/13/cloud
  fi
  host_incus project create "$CONSUMER_PROJECT" \
    -c features.images=false \
    -c features.profiles=true \
    -c features.storage.volumes=true >/dev/null
  host_incus project set "$CONSUMER_PROJECT" user.subyard.release-catchup="$MARKER"
  host_incus profile device add default root disk \
    path=/ pool=default --project "$CONSUMER_PROJECT" >/dev/null
  host_incus profile device add default eth0 nic \
    name=eth0 network=incusbr0 --project "$CONSUMER_PROJECT" >/dev/null
  host_incus launch "$image" "$CONSUMER_INSTANCE" \
    --project "$CONSUMER_PROJECT" \
    -c user.subyard.managed=true \
    -c user.subyard.name=default \
    -c user.subyard.initialized=true \
    -c user.subyard.desired_power=running \
    -c user.subyard.bridge=incusbr0 \
    -c boot.autostart=false >/dev/null
  for _ in $(seq 1 120); do
    host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- true \
      >/dev/null 2>&1 && break
    sleep 1
  done
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- true \
    >/dev/null 2>&1 || die "consumer container did not become ready"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    /bin/sh -c 'command -v git >/dev/null 2>&1 &&
      command -v jq >/dev/null 2>&1 &&
      command -v ssh >/dev/null 2>&1 || {
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git jq openssh-client
      }'
  ! host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes type \
    --project "$CONSUMER_PROJECT" >/dev/null 2>&1 \
    || die "legacy consumer unexpectedly has the route mount"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    awk '{print $22}' /proc/1/stat > "$STATE_ROOT/consumer-starttime"
  ok "running legacy consumer exists without the route mount"
}

prepare_legacy_owner() {
  host_incus project create "$LEGACY_PROJECT" \
    -c features.images=false \
    -c user.subyard.release-catchup="$MARKER" >/dev/null
  info "initializing published $OLD_VERSION e2e-yard"
  operator_yard -Y e2e-yard init --yes
  operator_yard -Y e2e-yard start --yes
  operator_yard -Y e2e-yard check
  [ "$(host_incus config get "$LEGACY_INSTANCE" user.subyard.managed \
    --project "$LEGACY_PROJECT")" = true ] \
    || die "legacy owner instance is not managed"
  operator_yard -Y e2e-yard test-vms status >/dev/null
  ok "published $OLD_VERSION legacy owner is ready"
}

upgrade_through_missed_release() {
  [ "$MODE" = missed ] || return 0
  info "updating through published yard $MISSED_VERSION"
  operator_yard update --version "$MISSED_VERSION" --yes
  [ "$(operator_yard --version)" = "yard $MISSED_VERSION" ] \
    || die "published $MISSED_VERSION runtime is not active"
  [ -f "$OPERATOR_HOME/.config/subyard/yards/e2e-yard/config.env" ] \
    || die "$MISSED_VERSION unexpectedly migrated the legacy registration"
  host_incus project show "$LEGACY_PROJECT" >/dev/null \
    || die "$MISSED_VERSION unexpectedly migrated the legacy project"
  ! host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes type \
    --project "$CONSUMER_PROJECT" >/dev/null 2>&1 \
    || die "$MISSED_VERSION unexpectedly reconciled the legacy consumer"
  ok "published $MISSED_VERSION reproduced the missed migration"
}

upgrade_candidate() {
  info "running ordinary yard update to $CANDIDATE_VERSION"
  operator_env env YARD_RELEASE_BASE_URL="file://$CANDIDATE_RELEASE" \
    "$OPERATOR_HOME/.local/bin/yard" update \
    --version "$CANDIDATE_VERSION" --yes
  [ "$(operator_yard --version)" = "yard $CANDIDATE_VERSION" ] \
    || die "candidate runtime is not active"
}

verify_control_plane() {
  local actual_start source="$OPERATOR_HOME/.subyard/e2e/routes"
  [ ! -e "$OPERATOR_HOME/.config/subyard/yards/e2e-yard" ] \
    || die "legacy registration directory remains"
  [ -f "$OPERATOR_HOME/.config/subyard/yards/test-yard/config.env" ] \
    || die "canonical registration is unavailable"
  ! host_incus project show "$LEGACY_PROJECT" >/dev/null 2>&1 \
    || die "legacy owner project remains"
  host_incus project show "$CURRENT_PROJECT" >/dev/null \
    || die "canonical owner project is unavailable"
  host_incus project set "$CURRENT_PROJECT" user.subyard.release-catchup="$MARKER"
  [ "$(host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes type \
    --project "$CONSUMER_PROJECT")" = disk ] \
    && [ "$(host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes source \
      --project "$CONSUMER_PROJECT")" = "$source" ] \
    && [ "$(host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes path \
      --project "$CONSUMER_PROJECT")" = /var/lib/subyard/e2e-routes ] \
    && [ "$(host_incus config device get "$CONSUMER_INSTANCE" subyard-e2e-routes readonly \
      --project "$CONSUMER_PROJECT")" = true ] \
    || die "consumer route device did not converge"
  actual_start="$(host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    awk '{print $22}' /proc/1/stat)"
  [ "$actual_start" = "$(cat "$STATE_ROOT/consumer-starttime")" ] \
    || die "consumer restarted during route reconciliation"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    test -r /var/lib/subyard/e2e-routes/test-yard/current/route.tsv
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    test -r /var/lib/subyard/e2e-routes/test-yard/current/known_hosts
  operator_yard -Y test-yard status >/dev/null
  operator_yard -Y test-yard check
  operator_test_vms_status \
    | jq -e '.pool.slots | length == 2 and all(.state == "available")' >/dev/null
  operator_env jq -e \
    '.layout == 2 and .applied == ["migrate-test-yard-owner"]' \
    "$OPERATOR_HOME/.config/subyard/migrations/state.json" >/dev/null
  ok "owner, route publication, live consumer and layout converged without restart"
}

verify_data_plane() {
  local bundle="$STATE_ROOT/public-worktree.tar.gz"
  local guest_bundle=/tmp/subyard-release-catchup.tar.gz
  local guest_source=/tmp/subyard-release-catchup-src
  info "running standard broker acquire from the pre-existing consumer"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    sh -c 'id dev >/dev/null 2>&1 || useradd --create-home --shell /bin/bash dev'
  (
    cd "$ROOT"
    git ls-files --cached --others --exclude-standard -z \
      | sort -z \
      | tar --null -T - -czf "$bundle"
  )
  host_incus file push "$bundle" "$CONSUMER_INSTANCE$guest_bundle" \
    --project "$CONSUMER_PROJECT" >/dev/null
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    install -d -m 0755 "$guest_source"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    tar -xzf "$guest_bundle" -C "$guest_source"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    find "$guest_bundle" -delete
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    chown -R dev:dev "$guest_source"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    runuser -u dev -- env \
      HOME=/home/dev USER=dev LOGNAME=dev SUBYARD_E2E_CONSUMER_FIXTURE=1 \
      bash "$guest_source/dev/e2e/release-migration-consumer.sh"
  host_incus exec "$CONSUMER_INSTANCE" --project "$CONSUMER_PROJECT" -- \
    find "$guest_source" -depth -delete
  operator_test_vms_status \
    | jq -e '.pool.slots | all(.state == "available")' >/dev/null
  host_incus exec "$CURRENT_INSTANCE" --project "$CURRENT_PROJECT" -- \
    incus list --all-projects --format json \
    | jq -e '
        [.[] | select(.name == "e2e-vm-1" or .name == "e2e-vm-2")] as $vms |
        ($vms | length) == 2 and all($vms[]; .status == "Stopped")
      ' >/dev/null
  ok "standard acquire, boundary and retained stopped pair passed"
}

prepare_host
prepare_operator
prepare_candidate
install_old_runtime
prepare_consumer
prepare_legacy_owner
upgrade_through_missed_release
upgrade_candidate
verify_control_plane
verify_data_plane
printf 'ok: published %s %s lane converged through the candidate\n' "$OLD_VERSION" "$MODE"
