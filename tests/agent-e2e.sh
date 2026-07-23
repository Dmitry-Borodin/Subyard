#!/usr/bin/env bash
# Agent E2E transport copies dirty public inputs, preserves argv and owns only run directories.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export SUBYARD_E2E_STATE_DIR="$TMP/client"
export SUBYARD_E2E_SHARED_ROUTE_DIR="$TMP/shared-route"

# shellcheck source=dev/agent-e2e.sh
. "$ROOT/dev/agent-e2e.sh"

[ "$E2E_YARD" = test-yard ] || fail "agent runner default yard is not test-yard"
[ "$STATE_ROOT" = "$TMP/client/yards/test-yard" ] \
  || fail "default generated client state is not yard-scoped"
[ "$IDENTITY" = "$TMP/client/id_ed25519" ] \
  || fail "controller identity is not shared outside yard-scoped state"

scope_snapshot="$(
  env -u SUBYARD_E2E_BASTION_ROUTE -u SUBYARD_E2E_SHARED_ROUTE_DIR \
    -u SUBYARD_E2E_STATE_DIR -u SUBYARD_E2E_YARD_STATE_DIR -u SUBYARD_E2E_IDENTITY \
    -u SUBYARD_E2E_YARD SUBYARD_HOME="$TMP/default-client" \
    bash -c '
      set -euo pipefail
      . "$1/dev/agent-e2e.sh"
      printf "%s|%s|%s|%s|%s\n" \
        "$E2E_YARD" "$BASTION_ROUTE" "$SHARED_ROUTE_DIR" "$STATE_ROOT" "$IDENTITY"
      E2E_YARD=e2e-yard
      configure_yard_scope
      printf "%s|%s|%s|%s|%s\n" \
        "$E2E_YARD" "$BASTION_ROUTE" "$SHARED_ROUTE_DIR" "$STATE_ROOT" "$IDENTITY"
    ' _ "$ROOT"
)"
expected_scope_snapshot="$(printf '%s\n%s\n' \
  "test-yard|yard-test-yard|$ROOT/temp/agent-e2e/test-yard|$TMP/default-client/e2e/yards/test-yard|$TMP/default-client/e2e/id_ed25519" \
  "e2e-yard|yard-e2e-yard|$ROOT/temp/agent-e2e/e2e-yard|$TMP/default-client/e2e/yards/e2e-yard|$TMP/default-client/e2e/id_ed25519")"
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
! printf '%s\n' "$contents" | grep -Fxq removed.txt || fail "deleted tracked file entered the bundle"
! printf '%s\n' "$contents" | grep -Eq '(^|/)(private|temp|\.git)(/|$)|ignored\.secret' \
  || fail "ignored or private data entered the worktree bundle"

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
quoted="$(quote_ssh_command bash -c 'test "$1" = "argument with spaces"' _ 'argument with spaces')"
bash -c "$quoted" || fail "direct SSH command did not preserve its argv"

# Accept only two ready, unexpired VMs with pinned host keys.
ensure_state_root
manifest="$(printf 'subyard-e2e-allocation-v1\nstate\tready\nreason\tready\nallocation_id\t123\nexpires_at_epoch\t%s\nvm\t1\te2e-vm-1\t10.42.0.11\tssh-ed25519\tAAAA1111\nvm\t2\te2e-vm-2\t10.42.0.12\tssh-ed25519\tAAAA2222\n' "$(( $(date +%s) + 600 ))")"
parse_allocation_manifest "$manifest"
[ "${VM_IP[1]}" = 10.42.0.11 ] && [ "${VM_IP[2]}" = 10.42.0.12 ] \
  || fail "allocation manifest lost the exact VM targets"
grep -Fxq 'e2e-vm-1 ssh-ed25519 AAAA1111' "$GUEST_KNOWN_HOSTS" \
  || fail "VM1 host-key pin was not materialized"
if (parse_allocation_manifest $'subyard-e2e-allocation-v1\nstate\tdown\nreason\toperator-down\n') >/dev/null 2>&1; then
  fail "down allocation was accepted"
fi

ensure_identity
[ -f "$SHARED_ROUTE_DIR/agent-access.pub" ] \
  || fail "controller identity did not publish an enrollment request"
[ "$(normalized_public_key_file "$IDENTITY.pub")" = "$(cat "$SHARED_ROUTE_DIR/agent-access.pub")" ] \
  || fail "published enrollment key does not match the controller identity"
[ "$(stat -c '%a' "$SHARED_ROUTE_DIR/agent-access.pub")" = 644 ] \
  || fail "published enrollment request is not public-key readable"
[ ! -e "$SHARED_ROUTE_DIR/id_ed25519" ] \
  || fail "controller private key entered the shared worktree directory"
# Enrollment accepts only the ignored public request.
# shellcheck source=scripts/lib/e2e-agent-enrollment.sh
. "$ROOT/scripts/lib/e2e-agent-enrollment.sh"
e2e_agent_enrollment_read "$SHARED_ROUTE_DIR" \
  || fail "product enrollment reader rejected the helper's public request"
[ "$E2E_AGENT_PUBLIC_KEY" = "$(normalized_public_key_file "$IDENTITY.pub")" ] \
  || fail "product enrollment reader did not normalize the requested key"
printf 'ssh-rsa invalid\n' > "$SHARED_ROUTE_DIR/agent-access.pub"
if e2e_agent_enrollment_read "$SHARED_ROUTE_DIR"; then
  fail "product enrollment reader accepted a non-Ed25519 key"
fi
ensure_identity
BASTION_HOSTNAME=127.0.0.1
BASTION_PORT=2223
BASTION_HOST_KEY_ALIAS=''
BASTION_KNOWN_HOSTS="$TMP/bastion-known-hosts"
printf '[127.0.0.1]:2223 %s\n' "$(normalized_public_key_file "$IDENTITY.pub")" > "$BASTION_KNOWN_HOSTS"
write_client_config
grep -Fxq '    ProxyJump subyard-e2e-bastion' "$CLIENT_CONFIG" \
  || fail "VM aliases do not use the restricted bastion"
grep -Fxq '    ForwardAgent no' "$CLIENT_CONFIG" \
  || fail "generated SSH config permits agent forwarding"
[ "$(grep -c '^Host e2e-vm-' "$CLIENT_CONFIG")" -eq 2 ] \
  || fail "generated SSH config does not expose exactly two VM aliases"
[ "$(grep '^[[:space:]]*IdentityFile ' "$CLIENT_CONFIG" | sort -u | wc -l)" -eq 1 ] \
  || fail "one controller identity was not reused consistently for both VM targets"

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
resolve_bastion_route
[ "$BASTION_HOSTNAME:$BASTION_PORT" = 127.0.0.1:2223 ] \
  || fail "bastion route was not resolved from the isolated user SSH config"
[ "$BASTION_KNOWN_HOSTS" = "$TMP/bastion-known-hosts" ] \
  || fail "bastion route did not reuse its pre-pinned host key"

mkdir -p "$SHARED_ROUTE_DIR"
cat > "$SHARED_ROUTE_DIR/route.tsv" <<'EOF'
subyard-e2e-route-v1
hostname	10.24.0.8
port	22
host_key_alias	subyard-e2e-bastion
EOF
printf 'subyard-e2e-bastion %s\n' "$(normalized_public_key_file "$IDENTITY.pub")" \
  > "$SHARED_ROUTE_DIR/known_hosts"
BASTION_HOSTNAME=''; BASTION_PORT=''; BASTION_HOST_KEY_ALIAS=''; BASTION_KNOWN_HOSTS=''
resolve_bastion_route
[ "$BASTION_HOSTNAME:$BASTION_PORT:$BASTION_HOST_KEY_ALIAS" = \
    10.24.0.8:22:subyard-e2e-bastion ] \
  || fail "root-published shared bastion route was not selected"
[ "$BASTION_KNOWN_HOSTS" = "$SHARED_ROUTE_DIR/known_hosts" ] \
  || fail "shared bastion route lost its pinned host key"

# Refresh through a private bootstrap config. The shared config must keep both VM aliases while the
# manifest probe is in flight, otherwise concurrent cleanup can fall back to DNS for e2e-vm-*.
write_client_config
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
grep -Fxq 'Host e2e-vm-1' "$EXPECTED_CLIENT_CONFIG"
grep -Fxq 'Host e2e-vm-2' "$EXPECTED_CLIENT_CONFIG"
cat "$FAKE_ALLOCATION_MANIFEST"
SH
chmod 0700 "$TMP/fake-bin/ssh"
printf '%s\n' "$manifest" > "$TMP/allocation.tsv"
EXPECTED_CLIENT_CONFIG="$CLIENT_CONFIG" FAKE_ALLOCATION_MANIFEST="$TMP/allocation.tsv" \
PATH="$TMP/fake-bin:$PATH" prepare_client
[ "$(grep -c '^Host e2e-vm-' "$CLIENT_CONFIG")" -eq 2 ] \
  || fail "manifest refresh did not publish a complete VM client config"

# Model direct guest SSH and cleanup locally.
guest() {
  shift
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
grep -Fq 'scripts/build-engine.sh --force' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not build an explicit source candidate"
grep -Fq 'scripts/install-runtime-release.sh' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not install an immutable candidate runtime"
grep -Fq 'RENAME_BASE_REVISION=' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not install the real pre-rename runtime"
grep -Fq 'write_owner_registration e2e-yard e2e-vms' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not exercise the retired registration"
grep -Fq './bin/yard -Y e2e-yard teardown --yes' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 owner lane does not teardown the migrated old yard"
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
grep -Fq 'YARD_ENGINE_PATH=%q' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer wrapper does not select its explicit candidate engine"
grep -Fq 'cleanup_peer_incus' "$ROOT/dev/e2e/p0-guest.sh" \
  || fail "P0 peer lane does not clean its Incus fixture"
! grep -Fq 'test-vms-inner' "$ROOT/dev/agent-e2e.sh" \
  || fail "agent E2E transport still invokes the privileged lifecycle worker"

printf 'ok: agent E2E uses pinned direct VM SSH and remains allocation-neutral and cleanup-owned\n'
