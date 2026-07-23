#!/usr/bin/env bash
# Developer checks on an allocated two-VM lab via restricted L1 SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/runtime.sh
. "$REPO_ROOT/scripts/lib/runtime.sh"

E2E_YARD="${SUBYARD_E2E_YARD:-test-yard}"
BASTION_USER="${SUBYARD_E2E_BASTION_USER:-subyard-e2e-agent}"
STATE_BASE="${SUBYARD_E2E_STATE_DIR:-${SUBYARD_HOME:-$(subyard_operator_home)/.subyard}/e2e}"
BASTION_ROUTE=""
SHARED_ROUTE_DIR=""
STATE_ROOT=""
IDENTITY=""
ENROLLMENT_PUBLIC_KEY=""
CLIENT_CONFIG=""
GUEST_KNOWN_HOSTS=""
BASTION_HOSTNAME=""
BASTION_PORT=""
BASTION_HOST_KEY_ALIAS=""
BASTION_KNOWN_HOSTS=""
ALLOCATION_MANIFEST=""
LOCAL_TEMP=""
PREPARED_DIRECTORY=""
declare -A GUEST_DIRS=()
declare -A VM_IP=()
declare -A VM_HOST_KEY=()

die() { printf 'agent-e2e: %s\n' "$*" >&2; exit 2; }
info() { printf '  [ .. ] %s\n' "$*"; }
ok() { printf '  [ ok ] %s\n' "$*"; }

configure_yard_scope() {
  case "$E2E_YARD" in
    '' | *[!a-z0-9_-]* | _* | -*) die "unsafe yard selector '$E2E_YARD'" ;;
  esac
  BASTION_ROUTE="${SUBYARD_E2E_BASTION_ROUTE:-yard-$E2E_YARD}"
  SHARED_ROUTE_DIR="${SUBYARD_E2E_SHARED_ROUTE_DIR:-$REPO_ROOT/temp/agent-e2e/$E2E_YARD}"
  STATE_ROOT="${SUBYARD_E2E_YARD_STATE_DIR:-$STATE_BASE/yards/$E2E_YARD}"
  IDENTITY="${SUBYARD_E2E_IDENTITY:-$STATE_BASE/id_ed25519}"
  ENROLLMENT_PUBLIC_KEY="$SHARED_ROUTE_DIR/agent-access.pub"
  CLIENT_CONFIG="$STATE_ROOT/ssh_config"
  GUEST_KNOWN_HOSTS="$STATE_ROOT/guest_known_hosts"
}

configure_yard_scope

usage() {
  cat <<'EOF'
Usage:
  dev/agent-e2e.sh [--yard NAME] --prepare
  dev/agent-e2e.sh [--yard NAME] [--vm 1|2|both] -- COMMAND [ARG...]
  dev/agent-e2e.sh [--yard NAME] --ssh 1|2 [-- COMMAND [ARG...]]
  dev/agent-e2e.sh [--yard NAME] --ssh-config
  dev/agent-e2e.sh [--yard NAME] --verify-boundary

The normal form copies the current tracked, dirty and non-ignored public worktree to each selected
VM, runs COMMAND as dev, streams output and removes every run directory. --ssh opens an ordinary
guest terminal (or runs a direct guest command). --ssh-config prints the generated strict OpenSSH
config path for direct `ssh -F PATH e2e-vm-1` use.

NAME defaults to test-yard. During a temporary migration, select the old yard explicitly with
`--yard e2e-yard`; route and generated client state remain isolated per yard.

--prepare creates or verifies the shared controller identity at ~/.subyard/e2e/id_ed25519 and
publishes only its public half to the selected yard's ignored
temp/agent-e2e/NAME/agent-access.pub enrollment request. One controller identity is authorized on
both VMs; each VM still has its own pinned SSH host key.

The operator must allocate the lab first. This command never starts, stops, creates or deletes a
yard, VM or inner Incus project, and it never obtains a shell in the privileged L1 yard.
EOF
}

ensure_state_root() {
  umask 077
  install -d -m 0700 "$STATE_ROOT"
}

normalized_public_key_file() {
  local file="$1" type blob _rest
  [ -r "$file" ] || return 1
  read -r type blob _rest < "$file"
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  printf '%s %s\n' "$type" "$blob"
}

ensure_identity() {
  local derived recorded type blob _rest
  ensure_state_root
  if [ ! -e "$IDENTITY" ] && [ ! -e "$IDENTITY.pub" ]; then
    ssh-keygen -q -t ed25519 -N '' -C subyard-e2e-agent -f "$IDENTITY"
  fi
  [ -s "$IDENTITY" ] && [ -s "$IDENTITY.pub" ] \
    || die "incomplete agent identity at $IDENTITY (both private and .pub files are required)"
  [ "$(stat -c '%a' "$IDENTITY")" = 600 ] || chmod 0600 "$IDENTITY"
  [ "$(stat -c '%a' "$IDENTITY.pub")" = 644 ] || chmod 0644 "$IDENTITY.pub"
  recorded="$(normalized_public_key_file "$IDENTITY.pub")" \
    || die "agent identity must use Ed25519"
  derived="$(ssh-keygen -y -f "$IDENTITY" 2>/dev/null)" \
    || die "cannot read the agent private identity"
  read -r type blob _rest <<<"$derived"
  derived="$type $blob"
  [ "$derived" = "$recorded" ] || die "agent identity public and private halves do not match"
  publish_enrollment_public_key "$recorded"
}

publish_enrollment_public_key() {
  local public_key="$1" temp
  [ ! -L "$SHARED_ROUTE_DIR" ] || die "shared E2E route directory must not be a symlink"
  install -d -m 0755 "$SHARED_ROUTE_DIR"
  [ ! -e "$ENROLLMENT_PUBLIC_KEY" ] || [ -f "$ENROLLMENT_PUBLIC_KEY" ] \
    || die "agent enrollment path is not a regular file: $ENROLLMENT_PUBLIC_KEY"
  [ ! -L "$ENROLLMENT_PUBLIC_KEY" ] \
    || die "agent enrollment path must not be a symlink: $ENROLLMENT_PUBLIC_KEY"
  temp="$(mktemp "$SHARED_ROUTE_DIR/.agent-access.XXXXXX")"
  printf '%s\n' "$public_key" > "$temp"
  chmod 0644 "$temp"
  mv -f -- "$temp" "$ENROLLMENT_PUBLIC_KEY"
}

prepare_enrollment() {
  ensure_identity
  ok "private controller identity ready at $IDENTITY"
  ok "public enrollment request written to $ENROLLMENT_PUBLIC_KEY"
  info "the operator can now reconcile it with: yard -Y $E2E_YARD init"
}

valid_route_word() { [[ "$1" =~ ^[A-Za-z0-9._:%-]+$ ]]; }

known_host_lookup_name() {
  if [ -n "$BASTION_HOST_KEY_ALIAS" ] && [ "$BASTION_HOST_KEY_ALIAS" != none ]; then
    printf '%s\n' "$BASTION_HOST_KEY_ALIAS"
  elif [ "$BASTION_PORT" = 22 ]; then
    printf '%s\n' "$BASTION_HOSTNAME"
  else
    printf '[%s]:%s\n' "$BASTION_HOSTNAME" "$BASTION_PORT"
  fi
}

resolve_bastion_route() {
  local rendered key value rest lookup candidate route_config="${SUBYARD_E2E_ROUTE_CONFIG:-${HOME:?}/.ssh/config}"
  local explicit_known="${SUBYARD_E2E_BASTION_KNOWN_HOSTS:-}"
  local header route_key route_value route_extra hostname_seen=0 port_seen=0 alias_seen=0
  local -a known_candidates=()
  local -a extra_known_candidates=()
  case "$BASTION_USER" in '' | -* | *[!a-z0-9_-]*) die "unsafe bastion user '$BASTION_USER'" ;; esac
  if [ -n "${SUBYARD_E2E_BASTION_HOSTNAME:-}" ]; then
    BASTION_HOSTNAME="$SUBYARD_E2E_BASTION_HOSTNAME"
    BASTION_PORT="${SUBYARD_E2E_BASTION_PORT:-22}"
    BASTION_HOST_KEY_ALIAS="${SUBYARD_E2E_BASTION_HOST_KEY_ALIAS:-}"
  elif [ -r "$SHARED_ROUTE_DIR/route.tsv" ] && [ -r "$SHARED_ROUTE_DIR/known_hosts" ]; then
    IFS= read -r header < "$SHARED_ROUTE_DIR/route.tsv"
    [ "$header" = subyard-e2e-route-v1 ] || die "shared bastion route has an unknown format"
    while IFS=$'\t' read -r route_key route_value route_extra; do
      [ -z "$route_extra" ] || die "shared bastion route contains an invalid record"
      case "$route_key" in
        subyard-e2e-route-v1 | '') ;;
        hostname) [ "$hostname_seen" = 0 ] || die "duplicate shared bastion hostname"; BASTION_HOSTNAME="$route_value"; hostname_seen=1 ;;
        port) [ "$port_seen" = 0 ] || die "duplicate shared bastion port"; BASTION_PORT="$route_value"; port_seen=1 ;;
        host_key_alias) [ "$alias_seen" = 0 ] || die "duplicate shared bastion host-key alias"; BASTION_HOST_KEY_ALIAS="$route_value"; alias_seen=1 ;;
        *) die "shared bastion route contains an unexpected record '$route_key'" ;;
      esac
    done < "$SHARED_ROUTE_DIR/route.tsv"
    [ "$hostname_seen$port_seen$alias_seen" = 111 ] || die "shared bastion route is incomplete"
    known_candidates=("$SHARED_ROUTE_DIR/known_hosts")
  else
    [ -r "$route_config" ] || route_config=/dev/null
    rendered="$(ssh -G -F "$route_config" "$BASTION_ROUTE" 2>/dev/null)" \
      || die "cannot resolve SSH route '$BASTION_ROUTE'"
    while read -r key value rest; do
      case "$key" in
        hostname) [ -n "$BASTION_HOSTNAME" ] || BASTION_HOSTNAME="$value" ;;
        port) [ -n "$BASTION_PORT" ] || BASTION_PORT="$value" ;;
        hostkeyalias) [ -n "$BASTION_HOST_KEY_ALIAS" ] || BASTION_HOST_KEY_ALIAS="$value" ;;
        userknownhostsfile)
          known_candidates+=("$value")
          read -r -a extra_known_candidates <<<"$rest"
          known_candidates+=("${extra_known_candidates[@]}")
          ;;
      esac
    done <<<"$rendered"
  fi
  [ -n "$BASTION_HOSTNAME" ] && valid_route_word "$BASTION_HOSTNAME" \
    || die "resolved bastion hostname is missing or unsafe"
  [[ "$BASTION_PORT" =~ ^[0-9]+$ ]] && [ "$BASTION_PORT" -ge 1 ] && [ "$BASTION_PORT" -le 65535 ] \
    || die "resolved bastion port is invalid"
  [ -z "$BASTION_HOST_KEY_ALIAS" ] || valid_route_word "$BASTION_HOST_KEY_ALIAS" \
    || die "resolved bastion host-key alias is unsafe"
  lookup="$(known_host_lookup_name)"
  if [ -n "$explicit_known" ]; then known_candidates=("$explicit_known"); fi
  for candidate in "${known_candidates[@]}"; do
    case "$candidate" in \~/*) candidate="${HOME:?}/${candidate#\~/}" ;; esac
    [ -r "$candidate" ] || continue
    if ssh-keygen -F "$lookup" -f "$candidate" >/dev/null 2>&1; then
      BASTION_KNOWN_HOSTS="$candidate"
      break
    fi
  done
  [ -n "$BASTION_KNOWN_HOSTS" ] || die \
    "no pinned host key for $lookup; the operator must re-run 'yard -Y $E2E_YARD init'"
}

ssh_config_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

render_client_config() {
  local selector alias
  {
    printf 'Host subyard-e2e-bastion\n'
    printf '    HostName %s\n' "$BASTION_HOSTNAME"
    printf '    Port %s\n' "$BASTION_PORT"
    printf '    User %s\n' "$BASTION_USER"
    printf '    IdentityFile '; ssh_config_value "$IDENTITY"; printf '\n'
    printf '    IdentitiesOnly yes\n'
    printf '    BatchMode yes\n'
    printf '    ForwardAgent no\n'
    printf '    RequestTTY no\n'
    printf '    StrictHostKeyChecking yes\n'
    printf '    UserKnownHostsFile '; ssh_config_value "$BASTION_KNOWN_HOSTS"; printf '\n'
    [ -z "$BASTION_HOST_KEY_ALIAS" ] || [ "$BASTION_HOST_KEY_ALIAS" = none ] \
      || printf '    HostKeyAlias %s\n' "$BASTION_HOST_KEY_ALIAS"
    if [ "${#VM_IP[@]}" -eq 2 ]; then
      for selector in 1 2; do
        alias="e2e-vm-$selector"
        printf '\nHost %s\n' "$alias"
        printf '    HostName %s\n' "${VM_IP[$selector]}"
        printf '    Port 22\n'
        printf '    User dev\n'
        printf '    IdentityFile '; ssh_config_value "$IDENTITY"; printf '\n'
        printf '    IdentitiesOnly yes\n'
        printf '    BatchMode yes\n'
        printf '    ForwardAgent no\n'
        printf '    ProxyJump subyard-e2e-bastion\n'
        printf '    HostKeyAlias %s\n' "$alias"
        printf '    StrictHostKeyChecking yes\n'
        printf '    UserKnownHostsFile '; ssh_config_value "$GUEST_KNOWN_HOSTS"; printf '\n'
      done
    fi
  }
}

write_client_config() {
  local temp
  temp="$(mktemp "$STATE_ROOT/.ssh-config.XXXXXX")"
  render_client_config > "$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$CLIENT_CONFIG"
}

valid_ipv4() {
  local address="$1" octet
  local -a octets=()
  IFS=. read -r -a octets <<<"$address"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -le 255 ] || return 1
  done
}

parse_allocation_manifest() {
  local manifest="$1" header kind first second third fourth fifth extra
  local state='' reason='' expires=0 seen=0 temp
  IFS= read -r header <<<"$manifest"
  [ "$header" = subyard-e2e-allocation-v1 ] || die "bastion returned an unknown status format"
  while IFS=$'\t' read -r kind first second third fourth fifth extra; do
    case "$kind" in
      subyard-e2e-allocation-v1 | '') ;;
      state) [ -z "$second$third$fourth$fifth$extra" ] || die "invalid state record"; state="$first" ;;
      reason) reason="$first" ;;
      allocation_id) [[ "$first" =~ ^[0-9]+$ ]] || die "invalid allocation id" ;;
      expires_at_epoch) [[ "$first" =~ ^[0-9]+$ ]] || die "invalid allocation expiry"; expires="$first" ;;
      vm)
        [ "$first" = 1 ] || [ "$first" = 2 ] || die "invalid VM selector in allocation status"
        [ "$second" = "e2e-vm-$first" ] || die "unexpected VM name in allocation status"
        valid_ipv4 "$third" || die "invalid VM address in allocation status"
        [ "$fourth" = ssh-ed25519 ] && [[ "$fifth" =~ ^[A-Za-z0-9+/=]+$ ]] && [ -z "$extra" ] \
          || die "invalid VM host key in allocation status"
        [ -z "${VM_IP[$first]:-}" ] || die "duplicate VM selector in allocation status"
        VM_IP[$first]="$third"
        VM_HOST_KEY[$first]="$fourth $fifth"
        seen=$((seen + 1))
        ;;
      *) die "unexpected allocation status record '$kind'" ;;
    esac
  done <<<"$manifest"
  [ "$state" = ready ] || die "VM lab is not ready (${reason:-state=${state:-missing}})"
  [ "$seen" -eq 2 ] || die "expected exactly two ready VM records"
  [ "$expires" -gt "$(date +%s)" ] || die "VM allocation has expired"
  temp="$(mktemp "$STATE_ROOT/.guest-known-hosts.XXXXXX")"
  printf 'e2e-vm-1 %s\ne2e-vm-2 %s\n' "${VM_HOST_KEY[1]}" "${VM_HOST_KEY[2]}" > "$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$GUEST_KNOWN_HOSTS"
}

prepare_client() {
  local manifest bootstrap_config
  command -v ssh >/dev/null 2>&1 || die "ssh is required"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
  ensure_identity
  resolve_bastion_route
  VM_IP=(); VM_HOST_KEY=()
  bootstrap_config="$(mktemp "$STATE_ROOT/.bootstrap-config.XXXXXX")"
  render_client_config > "$bootstrap_config"
  chmod 0600 "$bootstrap_config"
  if ! manifest="$(ssh -F "$bootstrap_config" -T subyard-e2e-bastion </dev/null)"; then
    rm -f "$bootstrap_config"
    die "cannot read allocation status with the enrolled agent identity; run 'dev/agent-e2e.sh --yard $E2E_YARD --prepare', then ask the operator to re-run 'yard -Y $E2E_YARD init'"
  fi
  rm -f "$bootstrap_config"
  parse_allocation_manifest "$manifest"
  ALLOCATION_MANIFEST="$manifest"
  write_client_config
}

verify_boundary() {
  local before after output vm pty_log transfer_log probe expected_hash actual_hash rc
  local -a requested=()
  prepare_client
  before="$ALLOCATION_MANIFEST"

  for probe in id 'sudo -n id' 'incus list' \
    'cat /var/lib/subyard/test-vms/worker-key' \
    '/usr/local/libexec/subyard/test-vms-worker up'; do
    read -r -a requested <<<"$probe"
    output="$(ssh -F "$CLIENT_CONFIG" -T subyard-e2e-bastion -- "${requested[@]}" </dev/null)" \
      || die "forced bastion status probe failed"
    [ "$output" = "$before" ] \
      || { printf 'agent-e2e: bastion executed a requested L1 command\n' >&2; return 1; }
  done

  pty_log="$(mktemp "$STATE_ROOT/.pty-probe.XXXXXX")"
  LC_ALL=C ssh -vv -F "$CLIENT_CONFIG" -tt subyard-e2e-bastion -- id </dev/null \
    > /dev/null 2> "$pty_log" || true
  grep -Fq 'PTY allocation request failed' "$pty_log" \
    || { rm -f "$pty_log"; printf 'agent-e2e: bastion did not reject a PTY request\n' >&2; return 1; }
  rm -f "$pty_log"

  for probe in sftp scp; do command -v "$probe" >/dev/null 2>&1 || die "$probe is required"; done
  transfer_log="$(mktemp "$STATE_ROOT/.transfer-probe.XXXXXX")"
  if sftp -F "$CLIENT_CONFIG" -b /dev/null subyard-e2e-bastion \
    </dev/null > /dev/null 2> "$transfer_log"; then
    rm -f "$transfer_log"
    printf 'agent-e2e: bastion allowed SFTP\n' >&2
    return 1
  fi
  probe="$(mktemp "$STATE_ROOT/.scp-probe.XXXXXX")"
  printf 'synthetic transfer probe\n' > "$probe"
  if scp -F "$CLIENT_CONFIG" -q "$probe" subyard-e2e-bastion:/tmp/subyard-e2e-agent-forbidden \
    </dev/null > /dev/null 2> "$transfer_log"; then
    rm -f "$probe" "$transfer_log"
    printf 'agent-e2e: bastion allowed SCP\n' >&2
    return 1
  fi
  rm -f "$probe" "$transfer_log"

  if ssh -F "$CLIENT_CONFIG" -T -o User=dev subyard-e2e-bastion -- true \
    </dev/null >/dev/null 2>&1; then
    printf 'agent-e2e: agent identity unexpectedly logged in as L1 dev\n' >&2
    return 1
  fi
  if ssh -F "$CLIENT_CONFIG" -T -W 127.0.0.1:22 subyard-e2e-bastion \
    </dev/null >/dev/null 2>&1; then
    printf 'agent-e2e: bastion allowed an unlisted forwarding target\n' >&2
    return 1
  fi

  for vm in 1 2; do
    [ "$(guest "$vm" sudo -n id -u </dev/null)" = 0 ] \
      || { printf 'agent-e2e: VM%s direct SSH/passwordless sudo failed\n' "$vm" >&2; return 1; }
    expected_hash="$(printf '\0subyard-binary-stdin\377' | sha256sum | awk '{print $1}')"
    actual_hash="$(printf '\0subyard-binary-stdin\377' | guest "$vm" sha256sum | awk '{print $1}')"
    [ "$actual_hash" = "$expected_hash" ] \
      || { printf 'agent-e2e: VM%s binary stdin changed in transport\n' "$vm" >&2; return 1; }
    set +e
    printf 'exit 23\n' | guest "$vm" /bin/sh -s >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" = 23 ] \
      || { printf 'agent-e2e: VM%s SSH exit status changed (%s)\n' "$vm" "$rc" >&2; return 1; }
    if printf '%s\n' \
      'set -eu' \
      'if timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; then exit 42; fi' \
      | ssh -F "$CLIENT_CONFIG" -T "e2e-vm-$vm" -- sudo -n bash -s -- "$BASTION_HOSTNAME"; then
      :
    else
      case "$?" in
        42) printf 'agent-e2e: VM%s root can reach L1 SSH management\n' "$vm" >&2; return 1 ;;
        *) printf 'agent-e2e: VM%s L1-isolation probe failed unexpectedly\n' "$vm" >&2; return 1 ;;
      esac
    fi
  done

  after="$(ssh -F "$CLIENT_CONFIG" -T subyard-e2e-bastion </dev/null)" \
    || die "post-probe allocation status failed"
  [ "$after" = "$before" ] \
    || { printf 'agent-e2e: boundary probes changed allocation state\n' >&2; return 1; }
  ok "VM SSH works; L1 commands, PTY, transfers, dev login, forwarding and guest return paths are blocked"
}

guest() {
  local vm="$1" command; shift
  command="$(quote_ssh_command "$@")"
  ssh -F "$CLIENT_CONFIG" -T "e2e-vm-$vm" -- "$command"
}

quote_ssh_command() {
  local argument quoted command=''
  [ "$#" -gt 0 ] || return 1
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="${command:+ }$quoted"
  done
  printf '%s\n' "$command"
}

cleanup_guest() {
  local vm="$1" directory="${GUEST_DIRS[$1]:-}"
  [ -n "$directory" ] || return 0
  case "$directory" in /tmp/subyard-worktree.*) ;; *) return 1 ;; esac
  guest "$vm" find "$directory" -depth -delete </dev/null
  unset 'GUEST_DIRS[$vm]'
}

cleanup_on_exit() {
  local rc=$? vm cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  for vm in "${!GUEST_DIRS[@]}"; do
    cleanup_guest "$vm" >/dev/null 2>&1 || cleanup_failed=1
  done
  if [ -n "$LOCAL_TEMP" ]; then
    case "$LOCAL_TEMP" in /tmp/subyard-agent-e2e.*|"${TMPDIR:-/tmp}"/subyard-agent-e2e.*)
      find "$LOCAL_TEMP" -depth -delete >/dev/null 2>&1 || cleanup_failed=1
      ;;
    esac
  fi
  [ "$cleanup_failed" = 0 ] || rc=3
  exit "$rc"
}

worktree_paths() {
  git ls-files --cached --others --exclude-standard -z
}

build_bundle() {
  local root="$1" bundle="$2" path resolved count=0
  local -a paths=()
  while IFS= read -r -d '' path; do
    if [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ]; then continue; fi
    case "$path" in
      '' | /* | ../* | */../* | .git | .git/* | private | private/* | temp | temp/*)
        die "refusing non-public worktree path '$path'"
        ;;
    esac
    if [ -L "$root/$path" ]; then
      resolved="$(realpath "$root/$path")" || die "cannot resolve symlink '$path'"
      case "$resolved" in "$root"/*) ;; *) die "refusing symlink outside the worktree: '$path'" ;; esac
    fi
    paths+=("$path")
    count=$((count + 1))
  done < <(cd "$root" && worktree_paths)
  [ "$count" -gt 0 ] || die "public worktree is empty"
  printf '%s\0' "${paths[@]}" | tar -C "$root" --null -T - -czf "$bundle"
}

write_guest_command() {
  local vm="$1" directory="$2"; shift 2
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'cd %q\n' "$directory/src"
  printf 'export SUBYARD_E2E_VM=%q\n' "$vm"
  printf 'exec'
  printf ' %q' "$@"
  printf '\n'
}

prepare_guest() {
  local vm="$1" bundle="$2" expected_hash="$3" directory actual_hash
  directory="$(guest "$vm" mktemp -d /tmp/subyard-worktree.XXXXXX </dev/null)" \
    || die "VM$vm did not create a run directory"
  case "$directory" in /tmp/subyard-worktree.*) ;; *) die "VM$vm returned an unsafe run directory" ;; esac
  GUEST_DIRS[$vm]="$directory"

  info "VM$vm: streaming current worktree" >&2
  guest "$vm" dd "of=$directory/worktree.tar.gz" status=none < "$bundle" \
    || die "VM$vm worktree transfer failed"
  actual_hash="$(guest "$vm" sha256sum "$directory/worktree.tar.gz" </dev/null | awk '{print $1}')" \
    || die "VM$vm checksum query failed"
  [ "$actual_hash" = "$expected_hash" ] || die "VM$vm worktree checksum mismatch"
  guest "$vm" mkdir "$directory/src" </dev/null || die "VM$vm source directory creation failed"
  guest "$vm" tar -xzf "$directory/worktree.tar.gz" -C "$directory/src" </dev/null \
    || die "VM$vm worktree extraction failed"
  PREPARED_DIRECTORY="$directory"
}

run_guest() {
  local vm="$1" bundle="$2" expected_hash="$3" directory; shift 3
  prepare_guest "$vm" "$bundle" "$expected_hash" || return
  directory="$PREPARED_DIRECTORY"
  write_guest_command "$vm" "$directory" "$@" \
    | guest "$vm" dd "of=$directory/run.sh" status=none \
    || die "VM$vm command transfer failed"
  guest "$vm" chmod 0700 "$directory/run.sh" </dev/null \
    || die "VM$vm command preparation failed"
  printf '\n== e2e-vm-%s ==\n' "$vm"
  guest "$vm" "$directory/run.sh" </dev/null
}

run_direct_ssh() {
  local vm="$1" command; shift
  prepare_client
  if [ "$#" -gt 0 ]; then
    command="$(quote_ssh_command "$@")"
    exec ssh -F "$CLIENT_CONFIG" -T "e2e-vm-$vm" -- "$command"
  fi
  exec ssh -F "$CLIENT_CONFIG" -tt "e2e-vm-$vm"
}

main() {
  local selector=both root bundle bundle_hash vm run_failed=0 cleanup_failed=0 mode=run ssh_vm=''
  local -a selected=() command=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yard) [ "$#" -ge 2 ] || die "--yard needs a yard name"; E2E_YARD="$2"; shift 2 ;;
      --vm) [ "$#" -ge 2 ] || die "--vm needs 1, 2 or both"; selector="$2"; shift 2 ;;
      --ssh) [ "$#" -ge 2 ] || die "--ssh needs 1 or 2"; mode=ssh; ssh_vm="$2"; shift 2 ;;
      --ssh-config) mode=config; shift ;;
      --prepare) mode=prepare; shift ;;
      --verify-boundary) mode=verify; shift ;;
      --) shift; command=("$@"); break ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown argument '$1' (put the guest command after --)" ;;
    esac
  done
  configure_yard_scope
  case "$mode" in
    prepare) [ "${#command[@]}" -eq 0 ] || die "--prepare takes no command"; prepare_enrollment; return ;;
    config) [ "${#command[@]}" -eq 0 ] || die "--ssh-config takes no command"; prepare_client; printf '%s\n' "$CLIENT_CONFIG"; return ;;
    verify) [ "${#command[@]}" -eq 0 ] || die "--verify-boundary takes no command"; verify_boundary; return ;;
    ssh)
      case "$ssh_vm" in 1 | 2) ;; *) die "--ssh needs VM selector 1 or 2" ;; esac
      run_direct_ssh "$ssh_vm" "${command[@]}"
      ;;
  esac

  [ "${#command[@]}" -gt 0 ] || die "a guest command is required after --"
  case "$selector" in 1) selected=(1) ;; 2) selected=(2) ;; both) selected=(1 2) ;; *) die "--vm must be 1, 2 or both" ;; esac
  root="$REPO_ROOT"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "agent E2E must run from a Git worktree"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

  prepare_client
  trap cleanup_on_exit EXIT INT TERM
  LOCAL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/subyard-agent-e2e.XXXXXX")"
  bundle="$LOCAL_TEMP/worktree.tar.gz"
  info "packing current public worktree"
  build_bundle "$root" "$bundle"
  bundle_hash="$(sha256sum "$bundle" | awk '{print $1}')"
  ok "worktree bundle ready (sha256=$bundle_hash)"

  for vm in "${selected[@]}"; do
    if ! run_guest "$vm" "$bundle" "$bundle_hash" "${command[@]}"; then run_failed=1; fi
    if ! cleanup_guest "$vm"; then
      printf 'agent-e2e: VM%s run directory cleanup failed\n' "$vm" >&2
      cleanup_failed=1
    fi
  done
  [ "$cleanup_failed" = 0 ] || return 3
  [ "$run_failed" = 0 ] || return 1
  ok "selected VM checks passed; run-specific worktrees removed"
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
