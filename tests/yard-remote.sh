#!/usr/bin/env bash
# Regression coverage for collision-free remote-yard SSH identities and fail-closed rotation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_contains() { grep -Fq -- "$2" <<<"$1" || fail "output does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" <<<"$1" || fail "output unexpectedly contains: $2"; }

mkdir -p "$TMP/bin" "$TMP/home/.ssh" "$TMP/state/keys" "$TMP/state/info" \
  "$TMP/state/data-mode" "$TMP/state/owner-mode" "$TMP/config-shipped"

# Real public keys keep known_hosts + ssh-keygen fingerprint/removal behavior realistic.
for key in controller local one two rotated three four stopped; do
  ssh-keygen -q -t ed25519 -N '' -f "$TMP/state/$key"
done
cp "$TMP/state/one.pub" "$TMP/state/keys/owner-one.pub"
cp "$TMP/state/one.pub" "$TMP/state/keys/yard-one.pub"
cp "$TMP/state/two.pub" "$TMP/state/keys/owner-two.pub"
cp "$TMP/state/two.pub" "$TMP/state/keys/yard-two.pub"
cp "$TMP/state/two.pub" "$TMP/state/keys/yard-named.pub"
cp "$TMP/state/three.pub" "$TMP/state/keys/owner-three.pub"
cp "$TMP/state/three.pub" "$TMP/state/keys/yard-three.pub"
cp "$TMP/state/four.pub" "$TMP/state/keys/owner-four.pub"
cp "$TMP/state/four.pub" "$TMP/state/keys/yard-four.pub"
cp "$TMP/state/stopped.pub" "$TMP/state/keys/owner-stopped.pub"
cp "$TMP/state/stopped.pub" "$TMP/state/keys/yard-stopped.pub"

set_info() { # <owner> <state>
  printf '{"name":"default","type":"local","version":"test","instance":"yard","project":"subyard","state":"%s","sshHost":"yard","sshPort":2222,"devUser":"dev","projects":0}\n' "$2" \
    > "$TMP/state/info/$1"
}
for owner in owner-one owner-two owner-three owner-four; do set_info "$owner" RUNNING; done
set_info owner-stopped STOPPED

# Mock only the transport. It models OpenSSH's important trust behavior: HostKeyAlias selects the
# known_hosts namespace, the key is learned before user authentication, and a changed key blocks.
cat > "$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = -G ]; then
  target="${2:-}"
  snip="$HOME/.ssh/subyard-${target#yard-}.config"
  printf 'hostname %s\nport 22\n' "$target"
  [ -f "$snip" ] && awk 'tolower($1)=="hostkeyalias" { print "hostkeyalias " $2; exit }' "$snip"
  exit 0
fi

dest=''; skip=0
for arg in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$arg" in
    -o) skip=1 ;;
    -*) ;;
    --) break ;;
    *) dest="$arg"; break ;;
  esac
done
[ -n "$dest" ] || exit 255
joined="$*"

if [[ "$joined" == *ssh-keyscan* ]]; then
  [ "$(cat "$REMOTE_TEST_ROOT/owner-mode/$dest" 2>/dev/null || true)" != unreachable ] || exit 255
  key="$(cut -d' ' -f1,2 "$REMOTE_TEST_ROOT/keys/$dest.pub")"
  printf '[127.0.0.1]:2222 %s\n' "$key"
  exit 0
fi
if [[ "$joined" == *_info* ]]; then
  [ "$(cat "$REMOTE_TEST_ROOT/owner-mode/$dest" 2>/dev/null || true)" != unreachable ] || exit 255
  cat "$REMOTE_TEST_ROOT/info/$dest"
  exit 0
fi
if [[ "$joined" == *_authorize* ]]; then
  cat >/dev/null
  exit 0
fi

case "$dest" in
  yard-*) ;;
  *) [ "$(cat "$REMOTE_TEST_ROOT/owner-mode/$dest" 2>/dev/null || true)" != unreachable ] || exit 255; exit 0 ;;
esac

snip="$HOME/.ssh/subyard-${dest#yard-}.config"
[ -f "$snip" ] || { printf 'ssh: Could not resolve hostname %s\n' "$dest" >&2; exit 255; }
alias="$(awk 'tolower($1)=="hostkeyalias" { print $2; exit }' "$snip")"
[ -n "$alias" ] || { printf 'ssh: missing HostKeyAlias\n' >&2; exit 255; }
known="$(awk 'tolower($1)=="userknownhostsfile" { print $2; exit }' "$snip")"
key="$(cut -d' ' -f1,2 "$REMOTE_TEST_ROOT/keys/$dest.pub")"
old="$(awk -v a="$alias" '$1==a { print $2 " " $3; exit }' "$known" 2>/dev/null || true)"
if [ -n "$old" ] && [ "$old" != "$key" ]; then
  printf '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n' >&2
  printf '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n' >&2
  printf 'Host key verification failed.\n' >&2
  exit 255
fi
if [ -z "$old" ]; then install -d -m 700 "$(dirname "$known")"; printf '%s %s\n' "$alias" "$key" >> "$known"; fi
mode="$(cat "$REMOTE_TEST_ROOT/data-mode/$dest" 2>/dev/null || true)"
case "$mode" in
  auth) printf 'dev@127.0.0.1: Permission denied (publickey).\n' >&2; exit 255 ;;
  proxy) printf 'channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\n' >&2; exit 255 ;;
esac
exit 0
MOCK
chmod 755 "$TMP/bin/ssh"

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SUBYARD_CONFIG_DIR="$TMP/config-shipped"
export SUBYARD_SSH_PUBKEY="$TMP/state/controller.pub"
export SUBYARD_NO_AUDIT=1
export YARD_VERSION=test
export REMOTE_TEST_ROOT="$TMP/state"

run_add() { "$ROOT/scripts/yard-remote.sh" add "$@" --yes; }

# A local port pin and two remote yards all use 2222. Only the per-context aliases distinguish
# the remote keys; unique control paths also prevent one ProxyJump connection being reused by another.
mkdir -p "$SUBYARD_HOME/ssh"
printf '[127.0.0.1]:2222 %s\n' "$(cut -d' ' -f1,2 "$TMP/state/local.pub")" \
  > "$SUBYARD_HOME/ssh/known_hosts"
output="$(run_add one owner-one)"
assert_contains "$output" 'sync <project-dir>'
assert_contains "$output" 'remote host can read everything explicitly synced'
assert_not_contains "$output" 'sync .'
run_add two owner-two >/dev/null
run_add named owner-two --yard inner >/dev/null
run_add named owner-two --yard inner >/dev/null
assert_file_contains "$HOME/.ssh/subyard-one.config" 'HostKeyAlias subyard-remote-one'
assert_file_contains "$HOME/.ssh/subyard-one.config" 'ControlPath '
assert_file_contains "$HOME/.ssh/subyard-one.config" 'cm-remote-one-'
assert_file_contains "$HOME/.ssh/subyard-two.config" 'HostKeyAlias subyard-remote-two'
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" '[127.0.0.1]:2222 '
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" 'subyard-remote-one '
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" 'subyard-remote-two '
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" 'subyard-remote-named '
assert_file_contains "$SUBYARD_CONFIG_HOME/yards/named.env" 'REMOTE_YARD=inner'
if output="$(run_add named owner-two --yard other 2>&1)"; then fail 'remote add allowed a remote-yard rebind'; fi
assert_contains "$output" 'before rebinding it'

# Identical add repairs a legacy snippet and stays idempotent; rebinding is rejected before probe.
printf 'FORWARD_SSH_AGENT=1\nCUSTOM_REMOTE_SETTING=kept\n' >> "$SUBYARD_CONFIG_HOME/yards/one.env"
sed -i '/HostKeyAlias/d' "$HOME/.ssh/subyard-one.config"
run_add one owner-one >/dev/null
run_add one owner-one >/dev/null
assert_file_contains "$HOME/.ssh/subyard-one.config" 'HostKeyAlias subyard-remote-one'
[ "$(grep -Fc 'FORWARD_SSH_AGENT=1' "$SUBYARD_CONFIG_HOME/yards/one.env")" = 1 ] || fail 'remote add did not preserve explicit forwarding opt-in'
[ "$(grep -Fc 'CUSTOM_REMOTE_SETTING=kept' "$SUBYARD_CONFIG_HOME/yards/one.env")" = 1 ] || fail 'remote add did not preserve user context overrides'
[ "$(grep -Fc 'Include subyard-one.config' "$HOME/.ssh/config")" = 1 ] || fail 'remote add duplicated the Include line'
if output="$(run_add one other-owner 2>&1)"; then fail 'remote add allowed a name rebind'; fi
assert_contains "$output" 'before rebinding it'

# A real key change is blocked. The failed identical add restores the old trust pin, then the
# explicit repair verifies the owner-host scan and changes only this context's entry.
old_one="$(awk '$1=="subyard-remote-one" { print $2 " " $3 }' "$SUBYARD_HOME/ssh/known_hosts")"
cp "$TMP/state/rotated.pub" "$TMP/state/keys/owner-one.pub"
cp "$TMP/state/rotated.pub" "$TMP/state/keys/yard-one.pub"
if output="$(run_add one owner-one 2>&1)"; then fail 'remote add accepted a changed host key'; fi
assert_contains "$output" 'yard ssh host key changed'
assert_contains "$output" 'remote repair-key one'
[ "$(awk '$1=="subyard-remote-one" { print $2 " " $3 }' "$SUBYARD_HOME/ssh/known_hosts")" = "$old_one" ] \
  || fail 'failed add changed the existing trust pin'
"$ROOT/scripts/yard-remote.sh" repair-key one --yes >/dev/null
new_one="$(cut -d' ' -f1,2 "$TMP/state/rotated.pub")"
[ "$(awk '$1=="subyard-remote-one" { print $2 " " $3 }' "$SUBYARD_HOME/ssh/known_hosts")" = "$new_one" ] \
  || fail 'repair-key did not pin the scanned replacement key'
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" '[127.0.0.1]:2222 '
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" 'subyard-remote-two '

# Steady-state data-plane preflights preserve and classify SSH failures instead of turning every
# error into a false "start it" hint.
run_reachable() {
  SUBYARD_YARD=one PROG=yard bash -c 'CONTROL_PLANE_ROOT="$1"; . "$1/tests/helpers/source-control-plane.sh"; . "$1/scripts/state/store.sh"; . "$1/scripts/state/resolver.sh"; . "$1/scripts/state/transport.sh"; . "$1/scripts/state/metadata.sh"; require_remote_reachable' _ "$ROOT"
}
cp "$TMP/state/four.pub" "$TMP/state/keys/yard-one.pub"
if output="$(run_reachable 2>&1)"; then fail 'changed-key reachability probe succeeded'; fi
assert_contains "$output" 'ssh host key changed'
assert_contains "$output" 'remote repair-key one'
cp "$TMP/state/rotated.pub" "$TMP/state/keys/yard-one.pub"

printf 'auth\n' > "$TMP/state/data-mode/yard-one"
if output="$(run_reachable 2>&1)"; then fail 'auth-failing reachability probe succeeded'; fi
assert_contains "$output" 'rejected this controller'
assert_not_contains "$output" 'start'

printf 'proxy\n' > "$TMP/state/data-mode/yard-one"
if output="$(run_reachable 2>&1)"; then fail 'proxy-failing reachability probe succeeded'; fi
assert_contains "$output" 'loopback proxy or sshd'
assert_not_contains "$output" 'state is STOPPED'

set_info owner-one STOPPED
if output="$(run_reachable 2>&1)"; then fail 'stopped reachability probe succeeded'; fi
assert_contains "$output" 'remote yard state is STOPPED'
assert_contains "$output" 'yard -Y one start'

set_info owner-one RUNNING
printf 'unreachable\n' > "$TMP/state/owner-mode/owner-one"
if output="$(run_reachable 2>&1)"; then fail 'owner-unreachable probe succeeded'; fi
assert_contains "$output" 'owner host for remote yard'
assert_not_contains "$output" 'state is STOPPED'
rm -f "$TMP/state/owner-mode/owner-one"

sed -i '/HostKeyAlias/d' "$HOME/.ssh/subyard-one.config"
if output="$(run_reachable 2>&1)"; then fail 'legacy-alias reachability probe succeeded'; fi
assert_contains "$output" 'missing or legacy'
rm -f "$TMP/state/data-mode/yard-one"
run_add one owner-one >/dev/null

# Auth/proxy/stopped failures are diagnosed accurately and leave no new context, snippet or pin.
printf 'auth\n' > "$TMP/state/data-mode/yard-three"
if output="$(run_add three owner-three 2>&1)"; then fail 'auth-failing add succeeded'; fi
assert_contains "$output" 'rejected the controller key'
assert_not_contains "$output" 'state is STOPPED'
[ ! -e "$SUBYARD_CONFIG_HOME/yards/three.env" ] || fail 'auth failure left a context'
[ ! -e "$HOME/.ssh/subyard-three.config" ] || fail 'auth failure left an ssh snippet'
! grep -Fq 'subyard-remote-three ' "$SUBYARD_HOME/ssh/known_hosts" || fail 'auth failure left a trust pin'

printf 'proxy\n' > "$TMP/state/data-mode/yard-four"
if output="$(run_add four owner-four 2>&1)"; then fail 'proxy-failing add succeeded'; fi
assert_contains "$output" 'loopback proxy or sshd failed'
assert_not_contains "$output" 'state is STOPPED'

printf 'proxy\n' > "$TMP/state/data-mode/yard-stopped"
if output="$(run_add stopped owner-stopped 2>&1)"; then fail 'stopped-yard add succeeded'; fi
assert_contains "$output" 'remote yard state is STOPPED'

# Confirmed removal owns exactly its alias pin, not a shared endpoint or sibling context.
"$ROOT/scripts/yard-remote.sh" remove two --yes >/dev/null
! grep -Fq 'subyard-remote-two ' "$SUBYARD_HOME/ssh/known_hosts" || fail 'remove kept the context trust pin'
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" '[127.0.0.1]:2222 '
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" 'subyard-remote-one '

"$ROOT/scripts/yard-remote.sh" remove named --yes >/dev/null
! grep -Fq 'subyard-remote-named ' "$SUBYARD_HOME/ssh/known_hosts" || fail 'named remove kept the context trust pin'

"$ROOT/scripts/yard-remote.sh" remove one --yes >/dev/null
! grep -Fq 'Include subyard-one.config' "$HOME/.ssh/config" || fail 'last remote Include survived removal'
assert_file_contains "$SUBYARD_HOME/ssh/known_hosts" '[127.0.0.1]:2222 '

printf 'ok: remote yards use isolated SSH identities, transactional add, and explicit key repair\n'
