#!/usr/bin/env bash
# Agent E2E transport copies dirty public inputs, preserves argv and owns only run directories.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_E2E_STATE_DIR="$TMP/client"

grep -Fq 'SUBYARD_E2E_ROUTE_REGISTRY:-/var/lib/subyard/e2e-routes' \
  "$ROOT/dev/agent-e2e.sh" \
  || fail 'runner does not use the boot-stable product route registry'
grep -Fq 'target=/var/lib/subyard/e2e-routes' "$ROOT/scripts/03-create-subyard.sh" \
  || fail 'yard route mount and runner registry path diverged'

# shellcheck source=dev/agent-e2e.sh
. "$ROOT/dev/agent-e2e.sh"

[ "$E2E_YARD" = test-yard ] || fail "agent runner default yard is not test-yard"
[ "$STATE_ROOT" = "$TMP/client/yards/test-yard" ] \
  || fail "default generated client state is not yard-scoped"
[ "$IDENTITY" = "$TMP/client/id_ed25519" ] \
  || fail "controller identity is not shared outside yard-scoped state"

scope_snapshot="$(
  env -u SUBYARD_E2E_BASTION_ROUTE \
    -u SUBYARD_E2E_STATE_DIR -u SUBYARD_E2E_YARD_STATE_DIR -u SUBYARD_E2E_IDENTITY \
    -u SUBYARD_E2E_YARD SUBYARD_HOME="$TMP/default-client" \
    bash -c '
      set -euo pipefail
      . "$1/dev/agent-e2e.sh"
      printf "%s|%s|%s|%s\n" \
        "$E2E_YARD" "$BASTION_ROUTE" "$STATE_ROOT" "$IDENTITY"
      E2E_YARD=e2e-yard
      configure_yard_scope
      printf "%s|%s|%s|%s\n" \
        "$E2E_YARD" "$BASTION_ROUTE" "$STATE_ROOT" "$IDENTITY"
    ' _ "$ROOT"
)"
expected_scope_snapshot="$(printf '%s\n%s\n' \
  "test-yard|yard-test-yard|$TMP/default-client/e2e/yards/test-yard|$TMP/default-client/e2e/id_ed25519" \
  "e2e-yard|yard-e2e-yard|$TMP/default-client/e2e/yards/e2e-yard|$TMP/default-client/e2e/id_ed25519")"
[ "$scope_snapshot" = "$expected_scope_snapshot" ] \
  || fail "test-yard and explicit e2e-yard route/state scopes collide: $scope_snapshot"
if "$ROOT/dev/agent-e2e.sh" --yard '../unsafe' --prepare >/dev/null 2>&1; then
  fail "agent runner accepted an unsafe yard selector"
fi

fixture="$TMP/worktree"
mkdir -p "$fixture/private" "$fixture/temp"
git -C "$fixture" init -q
printf 'private/\ntemp/\nignored.secret\n' > "$fixture/.gitignore"
printf 'tracked\n' > "$fixture/tracked.txt"
printf 'removed\n' > "$fixture/removed.txt"
printf 'dirty\n' > "$fixture/dirty.txt"
printf 'ignored\n' > "$fixture/ignored.secret"
printf 'private\n' > "$fixture/private/note.txt"
printf 'temp\n' > "$fixture/temp/cache.txt"
git -C "$fixture" add .gitignore tracked.txt removed.txt
printf 'changed\n' >> "$fixture/tracked.txt"
rm "$fixture/removed.txt"

bundle="$TMP/worktree.tar.gz"
build_bundle "$fixture" "$bundle"
contents="$(tar -tzf "$bundle" | sort)"
printf '%s\n' "$contents" | grep -Fxq dirty.txt || fail "dirty untracked file was not copied"
printf '%s\n' "$contents" | grep -Fxq tracked.txt || fail "modified tracked file was not copied"
printf '%s\n' "$contents" | grep -Fxq .subyard-e2e-index \
  || fail "tracked-file inventory was not copied"
! printf '%s\n' "$contents" | grep -Fxq removed.txt || fail "deleted tracked file entered the bundle"
! printf '%s\n' "$contents" | grep -Eq '(^|/)(private|temp|\.git)(/|$)|ignored\.secret' \
  || fail "ignored or private data entered the worktree bundle"
inventory="$(tar -xOf "$bundle" .subyard-e2e-index | tr '\0' '\n')"
printf '%s\n' "$inventory" | grep -Fxq tracked.txt \
  || fail "tracked-file inventory omitted a tracked path"
! printf '%s\n' "$inventory" | grep -Fxq dirty.txt \
  || fail "tracked-file inventory classified an untracked path as tracked"

ln -s /etc/passwd "$fixture/escaping-link"
if (build_bundle "$fixture" "$TMP/unsafe.tar.gz") >/dev/null 2>&1; then
  fail "worktree bundling accepted a symlink outside the repository"
fi
rm "$fixture/escaping-link"

command_root="$TMP/command path"
mkdir -p "$command_root/src"
write_guest_command 2 "$command_root" sh -c \
  'test "$SUBYARD_E2E_VM" = 2 && test "$1" = "argument with spaces"' fixture 'argument with spaces' \
  > "$TMP/run.sh"
bash "$TMP/run.sh" || fail "guest command did not preserve its argv or VM selector"
write_guest_command 1 "$command_root" ./bin/yard --version > "$TMP/yard-run.sh"
grep -Fxq './dev/build-engine.sh' "$TMP/yard-run.sh" \
  || fail "direct guest yard command does not build its explicit development engine"
grep -Fxq 'exec ./bin/yard --version' "$TMP/yard-run.sh" \
  || fail "direct guest yard command changed its argv after the development build"
quoted="$(quote_ssh_command bash -c 'test "$1" = "argument with spaces"' _ 'argument with spaces')"
bash -c "$quoted" || fail "direct SSH command did not preserve its argv"

mkdir -p "$TMP/direct-bin"
cat > "$TMP/direct-bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' e2e-vm-1 '*)
    IFS= read -r forwarded
    [ "$forwarded" = explicit-stdin ]
    ;;
  *)
    if IFS= read -r leaked; then
      printf 'direct SSH leaked stdin: %s\n' "$leaked" >&2
      exit 91
    fi
    ;;
esac
printf '%s\n' "$*"
SH
chmod +x "$TMP/direct-bin/ssh"
direct_ssh="$(
  PATH="$TMP/direct-bin:$PATH" ROOT="$ROOT" bash -c '
    set -euo pipefail
    . "$ROOT/dev/agent-e2e.sh"
    CLIENT_CONFIG=/tmp/direct-ssh-config
    printf "must-not-reach-ssh\n" | run_direct_ssh 2 0 printf "%s" "argument with spaces"
  '
)"
printf '%s\n' "$direct_ssh" | grep -Fq -- '-T e2e-vm-2 --' \
  || fail "direct SSH command did not use the pinned non-TTY VM route"
direct_ssh_stdin="$(
  PATH="$TMP/direct-bin:$PATH" ROOT="$ROOT" bash -c '
    set -euo pipefail
    . "$ROOT/dev/agent-e2e.sh"
    CLIENT_CONFIG=/tmp/direct-ssh-config
    printf "explicit-stdin\n" | run_direct_ssh 1 1 sh -c "read -r value"
  '
)"
printf '%s\n' "$direct_ssh_stdin" | grep -Fq -- '-T e2e-vm-1 --' \
  || fail "explicit direct SSH stdin did not use the pinned non-TTY VM route"
grep -Fq 'guest 1 \' "$ROOT/dev/e2e/p0-acceptance.sh" \
  && grep -Fq 'dd of="$1" status=none' "$ROOT/dev/e2e/p0-acceptance.sh" \
  || fail "P0 source archive does not use the lease-local stdin transport"
grep -Fq 'run_vm "$vm" capacity-preflight' "$ROOT/dev/e2e/p0-acceptance.sh" \
  && grep -Fq 'capacity-verify-cleanup' "$ROOT/dev/e2e/p0-acceptance.sh" \
  && grep -Fq 'capacity_report' "$ROOT/dev/e2e/p0-acceptance.sh" \
  || fail "P0 acceptance does not enforce capacity preflight, peak reporting and exact cleanup"
grep -Fq 'P0_E2E_MIN_PEAK_MEMORY_RESERVE_BYTES:-67108864' \
  "$ROOT/dev/e2e/p0-acceptance.sh" \
  || fail "P0 acceptance does not keep only the 64 MiB minimum peak memory reserve"
grep -Fq '> "$PEER_ROOT/config/config.env"' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'P0_PEER_YARD_TIMEOUT:-300' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer yard does not use its active config root with a bounded init"
grep -Fq '"$candidate_yard" _migrate finalize' \
  "$ROOT/scripts/migrate-source-install.sh" \
  && ! grep -Fq '_migrate-test-yard' "$ROOT/dev/bootstrap-runtime.sh" \
  || fail "source bootstrap does not use the generic ordered migration lifecycle"

 ensure_identity
lease_blob="$(awk '{print $2}' "$IDENTITY.pub")"
lease_response="$(printf '{"schema_version":1,"status":"ok","grant":{"slot_id":"slot-001","lease_id":"aabb","capability":"ccdd","lease_epoch":3,"data_user":"subyard-e2e-slot-1","targets":[{"selector":1,"name":"e2e-vm-1","address":"10.42.1.11","host_key_type":"ssh-ed25519","host_key_blob":"%s"},{"selector":2,"name":"e2e-vm-2","address":"10.42.1.12","host_key_type":"ssh-ed25519","host_key_blob":"%s"}]}}' "$lease_blob" "$lease_blob")"
parse_lease_grant "$lease_response" \
  || fail "valid lease grant was rejected"
[ "$LEASE_SLOT" = slot-001 ] && [ "$DATA_USER" = subyard-e2e-slot-1 ] \
  && [ "${VM_IP[1]}" = 10.42.1.11 ] && [ "${VM_IP[2]}" = 10.42.1.12 ] \
  || fail "lease grant did not materialize exact fenced transport state"
if (parse_lease_grant '{"status":"ok","grant":{"capability":"secret"}}') >/dev/null 2>&1; then
  fail "incomplete lease grant was accepted"
fi
ensure_identity
BASTION_HOSTNAME=127.0.0.1
BASTION_PORT=2223
BASTION_HOST_KEY_ALIAS=''
BASTION_KNOWN_HOSTS="$TMP/bastion-known-hosts"
DATA_USER=subyard-e2e-slot-1
GUEST_IDENTITY="$TMP/lease-key"
cp "$IDENTITY" "$GUEST_IDENTITY"
printf '[127.0.0.1]:2223 %s\n' "$(normalized_public_key_file "$IDENTITY.pub")" > "$BASTION_KNOWN_HOSTS"
write_client_config
grep -Fxq '    ProxyJump subyard-e2e-data' "$CLIENT_CONFIG" \
  && grep -Fxq '    User subyard-e2e-slot-1' "$CLIENT_CONFIG" \
  || fail "VM aliases do not use the lease-scoped data account"
grep -Fxq '    ForwardAgent no' "$CLIENT_CONFIG" \
  || fail "generated SSH config permits agent forwarding"
[ "$(grep -c '^Host e2e-vm-' "$CLIENT_CONFIG")" -eq 2 ] \
  || fail "generated SSH config does not expose exactly two VM aliases"
[ "$(grep '^[[:space:]]*IdentityFile ' "$CLIENT_CONFIG" | sort -u | wc -l)" -eq 2 ] \
  || fail "controller and ephemeral guest identities were not separated"

cat > "$TMP/route-config" <<EOF
Host fixture-e2e-yard
    HostName 127.0.0.1
    Port 2223
    UserKnownHostsFile $BASTION_KNOWN_HOSTS
EOF
# shellcheck disable=SC2100 # This is an SSH host alias, not an arithmetic expression.
BASTION_ROUTE=fixture-e2e-yard
BASTION_HOSTNAME=''; BASTION_PORT=''; BASTION_HOST_KEY_ALIAS=''; BASTION_KNOWN_HOSTS=''
SUBYARD_E2E_ROUTE_CONFIG="$TMP/route-config"
SUBYARD_E2E_ROUTE_REGISTRY="$TMP/empty-route-registry"
resolve_bastion_route
[ "$BASTION_HOSTNAME:$BASTION_PORT" = 127.0.0.1:2223 ] \
  || fail "bastion route was not resolved from the isolated user SSH config"
[ "$BASTION_KNOWN_HOSTS" = "$TMP/bastion-known-hosts" ] \
  || fail "bastion route did not reuse its pre-pinned host key"

route_registry="$TMP/route-registry"
mkdir -p "$route_registry/test-yard/.route-fixture"
ln -s .route-fixture "$route_registry/test-yard/current"
cat > "$route_registry/test-yard/current/route.tsv" <<'EOF'
subyard-e2e-route-v1
hostname	10.24.0.8
port	22
host_key_alias	subyard-e2e-bastion
EOF
printf 'subyard-e2e-bastion %s\n' "$(normalized_public_key_file "$IDENTITY.pub")" \
  > "$route_registry/test-yard/current/known_hosts"
BASTION_HOSTNAME=''; BASTION_PORT=''; BASTION_HOST_KEY_ALIAS=''; BASTION_KNOWN_HOSTS=''
SUBYARD_E2E_ROUTE_REGISTRY="$route_registry"
resolve_bastion_route
[ "$BASTION_HOSTNAME:$BASTION_PORT:$BASTION_HOST_KEY_ALIAS" = \
    10.24.0.8:22:subyard-e2e-bastion ] \
  || fail "root-published shared bastion route was not selected"
[ "$BASTION_KNOWN_HOSTS" = "$route_registry/test-yard/current/known_hosts" ] \
  || fail "product-owned bastion route lost its pinned host key"

# Model direct guest SSH and cleanup locally.
guest() {
  shift
  if [ "${1:-}" = sudo ] && [ "${2:-}" = -n ]; then shift 2; fi
  "$@"
}
mock_bundle="$TMP/mock.tar.gz"
tar -C "$fixture" -czf "$mock_bundle" tracked.txt
mock_hash="$(sha256sum "$mock_bundle" | awk '{print $1}')"
run_guest 1 "$mock_bundle" "$mock_hash" test -f tracked.txt \
  || fail "mock guest command failed"
guest_directory="${GUEST_DIRS[1]:-}"
case "$guest_directory" in /tmp/subyard-worktree.*) ;; *) fail "guest run directory was not retained for cleanup" ;; esac
[ -d "$guest_directory" ] || fail "mock guest run directory is missing"
cleanup_guest 1 || fail "guest run directory cleanup failed"
[ ! -e "$guest_directory" ] || fail "guest run directory survived cleanup"

set +e
bash -c '
  set -euo pipefail
  . "$1/dev/agent-e2e.sh"
  GUEST_DIRS[1]=/tmp/subyard-worktree.fixture
  cleanup_guest() { return 1; }
  cleanup_on_exit
' _ "$ROOT" >/dev/null 2>&1
cleanup_rc=$?
set -e
[ "$cleanup_rc" = 3 ] || fail "trap cleanup failure returned $cleanup_rc instead of 3"

if sed '/^[[:space:]]*#/d' "$ROOT/dev/agent-e2e.sh" \
  | grep -Eq 'test-vms[[:space:]]+(up|down)|yard[[:space:]].*(start|stop)'; then
  fail "agent E2E transport contains an allocation lifecycle call"
fi
if sed '/^[[:space:]]*#/d' "$ROOT/dev/e2e/p0-acceptance.sh" \
  | grep -Eq 'test-vms[[:space:]]+(up|down)|yard[[:space:]].*(start|stop)'; then
  fail "P0 acceptance contains an allocation lifecycle call"
fi
grep -Fq 'trap owner_cleanup EXIT' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not clean its candidate after failure"
grep -Fq 'prepare_owner_go_cache' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'p0_capacity_reset_build_cache' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'p0_capacity_remove_build_cache' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane leaves candidate Go caches on the disposable VM"
grep -Fq 'dev/build-engine.sh --force' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not build an explicit source candidate"
grep -Fq 'scripts/install-runtime-release.sh' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not install an immutable candidate runtime"
grep -Fq 'RENAME_BASE_REVISION=' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not install the real pre-rename runtime"
grep -Fq 'write_owner_registration e2e-yard e2e-vms' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not exercise the retired registration"
grep -Fq 'runtime activation retained the old e2e-yard registration' \
  "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not verify automatic retirement of the old yard"
grep -Fq 'features.images=false -c user.subyard.p0-image-cache="$MARKER"' \
  "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not attach its test-owned image cache before fresh reconciliation"
owner_bootstrap_line="$(grep -n $'^\tensure_owner_incus$' "$ROOT/dev/e2e/p0-guest.sh" | head -n1 | cut -d: -f1)"
owner_incus_line="$(grep -n 'OWNER_BASELINE_IMAGES=.*incus image list' "$ROOT/dev/e2e/p0-guest.sh" | head -n1 | cut -d: -f1)"
[ -n "$owner_bootstrap_line" ] && [ -n "$owner_incus_line" ] \
  && [ "$owner_bootstrap_line" -lt "$owner_incus_line" ] \
  || fail "P0 owner lane uses Incus before its disposable-VM bootstrap"
grep -Fq './bin/yard -Y test-yard start --yes' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not make start automation explicit"
grep -Fq 'shell "$source" --yes --' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not confirm shell automation"
grep -Fq 'export "$source" --yes' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not confirm export automation"
grep -Fq 'exec %q/yard "$@"' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq '"$release/subyard-install.sh" --yes' "$ROOT/dev/e2e/p0-guest.sh" \
  && ! grep -Fq 'YARD_ENGINE_PATH=%q' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer wrapper does not use its release-installed runtime"
grep -Fq 'PEER_YARD_ENTRY="$HOME/.local/bin/yard"' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'VM1 user yard entry was not restored exactly' "$ROOT/dev/e2e/p0-acceptance.sh" \
  && ! grep -Fq '/usr/local/bin/yard' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer wrapper does not preserve the login-PATH user entrypoint"
grep -Fq 'UserKnownHostsFile="$PEER_SSH_DIR/known_hosts"' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'ConnectTimeout=8' "$ROOT/dev/e2e/p0-guest.sh" \
  && grep -Fq 'id_ed25519"' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 cross-owner SSH lacks its synthetic identity, strict pin or bounded timeout"
grep -Fq 'remove_peer_authorization' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer cleanup does not revoke its synthetic SSH authorization"
credentials_line="$(grep -n '^peer_credentials()' "$ROOT/dev/e2e/p0-guest.sh" | cut -d: -f1)"
projects_line="$(grep -n '^peer_projects()' "$ROOT/dev/e2e/p0-guest.sh" | cut -d: -f1)"
remote_remove_line="$(grep -n 'remote remove peer --yes' "$ROOT/dev/e2e/p0-guest.sh" | cut -d: -f1)"
[ -n "$credentials_line" ] && [ -n "$projects_line" ] && [ -n "$remote_remove_line" ] \
  && [ "$remote_remove_line" -gt "$credentials_line" ] \
  && [ "$remote_remove_line" -lt "$projects_line" ] \
  || fail "P0 peer alias is removed before its credentials consumer finishes"
grep -Fq 'incus "$@" </dev/null; }' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'real_incus_quiet launch "$VM_IMAGE" p0-vm' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'CONTAINER_CACHE_ALIAS="${P0_REAL_INCUS_CONTAINER_CACHE_ALIAS:-' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'VM_CACHE_ALIAS="${P0_REAL_INCUS_VM_CACHE_ALIAS:-' "$ROOT/dev/e2e/p0-real-incus.sh" \
  || fail "P0 real-Incus lane leaves YAML-reading control-plane stdin open"
grep -Fq 'wait_ready p0-container container' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'wait_ready p0-vm virtual-machine' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq -- '-c security.secureboot=false' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'stopped during first boot; replacing it once' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'relaunching real Incus VM after first-boot stop' "$ROOT/dev/e2e/p0-real-incus.sh" \
  || fail "P0 real-Incus lane does not bound first-boot VM recovery with deterministic boot policy"
grep -Fq 'cleanup delete of %s failed; retrying (%s/3)' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'refusing to delete unmarked instance' "$ROOT/dev/e2e/p0-real-incus.sh" \
  && grep -Fq 'could not delete marked instance $name after 3 attempts' "$ROOT/dev/e2e/p0-real-incus.sh" \
  || fail "P0 real-Incus cleanup retry is not bounded to marked test instances"
grep -Fq 'guest "$vm" \' "$ROOT/dev/e2e/p0-acceptance.sh" \
  || fail "P0 peer cleanup assertion bypasses direct-command argv quoting"
grep -Fq 'cleanup_peer_incus' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer lane does not clean its Incus fixture"
grep -Fq '. "$ROOT/tests/helpers/test-context.sh"' "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  && grep -Fq 'run_incus_installer --yes --zabbly' "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  && ! grep -Fq '"$ROOT/scripts/01-install-incus.sh" --yes --zabbly' \
    "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  || fail "P0 source-upgrade bootstrap bypasses the typed test engine context"
! grep -Fq '"$SOURCE_ROOT/config/qa-pool/"*' "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  || fail "P0 source-upgrade fixture expands operator-private paths as the outer user"
grep -Fq 's/^YARD_TEMPLATE=e2e-vms$/YARD_TEMPLATE=test-vms/' \
  "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  || fail "P0 source-upgrade lane does not verify the retired template migration"
grep -Fq 'migration_transaction_directory "$VERSION_B"' \
  "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  && grep -Fq 'to_release="$(jq -er ".toRelease' \
    "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  && ! grep -Fq '[ "${#entries[@]}" -eq 1 ]' \
    "$ROOT/dev/e2e/p0-source-upgrade.sh" \
  || fail "P0 source-upgrade lane does not select its journal by release identity"
grep -Fq 'OLD_VERSION=0.3.1' "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq 'MISSED_VERSION=0.4.0' "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq 'host_incus config device get "$CONSUMER_INSTANCE"' \
    "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq 'running standard broker acquire from the pre-existing consumer' \
    "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq 'consumer restarted during route reconciliation' \
    "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  || fail "release catch-up lanes do not cover both published histories and live consumer routing"
grep -Fq 'cleanup_owned_host_incus' "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq '[ "$source" = "$PLATFORM_STORAGE" ]' \
    "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  && grep -Fq 'host_incus storage delete default --project default' \
    "$ROOT/dev/e2e/release-migration-catch-up.sh" \
  || fail "release catch-up cleanup can leave its fixture-owned default Incus pool behind"
grep -Fq 'dev/agent-e2e.sh --wait 20m --vm both' \
  "$ROOT/dev/e2e/release-migration-consumer.sh" \
  && grep -Fq 'dev/agent-e2e.sh --verify-boundary' \
    "$ROOT/dev/e2e/release-migration-consumer.sh" \
  || fail "release catch-up consumer bypasses the standard broker facade"
grep -Fq 'select(.slot_id == $slot)' "$ROOT/dev/agent-e2e.sh" \
  && grep -Fq 'current lease slot is absent from pool status' "$ROOT/dev/agent-e2e.sh" \
  || fail "agent E2E boundary verification is coupled to unrelated concurrent slots"
! grep -Fq 'test-vms-inner' "$ROOT/dev/agent-e2e.sh" \
  || fail "agent E2E transport still invokes the privileged lifecycle worker"

printf 'ok: agent E2E lease transport is pinned, fenced and cleanup-owned\n'
