#!/usr/bin/env bash
# security-lint.sh — read-only host-boundary contract checks for config and live Incus state.
# Usage: yard security [--require-live] [--quiet]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${SUBYARD_ENGINE_CONTEXT:-}" = 1 ] \
  || { printf 'security-lint: prepared engine context required\n' >&2; exit 2; }
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"

quiet=0
require_live=0
for arg in "$@"; do
  case "$arg" in
    --quiet) quiet=1 ;;
    --require-live) require_live=1 ;;
    -y | --yes) ;;
    -h | --help) ;;
    *) die "unknown option '$arg'" ;;
  esac
done

failures=0
warnings=0
security_fail() { printf '  [fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
security_warn() { [ "$quiet" = 1 ] || printf '  [warn] %s\n' "$*" >&2; warnings=$((warnings + 1)); }
security_ok() { [ "$quiet" = 1 ] || printf '  [ ok ] %s\n' "$*"; }

check_mount_entry() { # <kind> <name:path:ro:mode>
  local kind="$1" entry="$2" name path access mode
  IFS=: read -r name path access mode <<<"$entry"
  case "$name" in '' | *[!A-Za-z0-9._-]*) security_fail "$kind mount has unsafe name: $name" ;; esac
  case "$path" in /*) ;; *) security_fail "$kind mount target must be absolute: $path" ;; esac
  case "$access" in ro | rw | '') ;; *) security_fail "$kind mount access must be ro or rw: $entry" ;; esac
  case "$mode" in '' | 0[0-7][0-7][0-7]) ;; *) security_fail "$kind mount mode must be octal: $entry" ;; esac
  case "${path,,}" in
    / | */docker.sock | */incus.sock | */lxd.sock)
      security_fail "$kind mount targets a forbidden host-control path: $path" ;;
  esac
}

# config/context modules already validated the loaded context; lint owns the remaining contract.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  check_mount_entry HOST_MOUNTS "$entry"
done < <(printf '%s\n' "${HOST_MOUNTS:-}" | sed 's/[[:space:]]//g')

profiles_dir="${SUBYARD_PROFILES_DIR:-$SCRIPT_DIR/../config/profiles}"
for profile in "$profiles_dir"/*/profile.conf; do
  [ -r "$profile" ] || continue
  while IFS= read -r record; do
    kind="${record%% *}"; value="${record#* }"
    case "$kind" in
      YARD) check_mount_entry "$(basename "$(dirname "$profile")") YARD_MOUNTS" "$value" ;;
      ENV)
        case "${value,,}" in
          */docker.sock* | */incus.sock* | */lxd.sock*)
            security_fail "$(basename "$(dirname "$profile")") ENV_MOUNTS exposes a host-control socket: $value" ;;
        esac ;;
    esac
  done < <(
    # shellcheck disable=SC1090
    . "$profile"
    for value in ${YARD_MOUNTS:-}; do printf 'YARD %s\n' "$value"; done
    for value in ${ENV_MOUNTS:-}; do printf 'ENV %s\n' "$value"; done
  )
done

[ "${FORWARD_SSH_AGENT:-0}" = 0 ] \
  || security_warn "SSH agent forwarding is enabled; this is operator opt-in, not a credential boundary"

# The encrypted ledger is host control-plane state. It must not sit in either Git checkout or
# beneath HOST_BASE (managed mounts source their data there), and private identities stay 0600.
keys_root="$(realpath -m "${SUBYARD_KEYS_ROOT:-$SUBYARD_CONFIG_HOME/keys}")"
repo_root="$(realpath -m "$SCRIPT_DIR/..")"
host_base_real="$(realpath -m "$HOST_BASE")"
if path_is_within "$keys_root" "$repo_root"; then
  security_fail "SUBYARD_KEYS_ROOT is inside the public/private checkout: $keys_root"
fi
if path_is_within "$keys_root" "$host_base_real"; then
  security_fail "SUBYARD_KEYS_ROOT is beneath HOST_BASE and could become a yard mount: $keys_root"
fi
if [ -d "$keys_root" ]; then
  mode="$(stat -c '%a' "$keys_root" 2>/dev/null || true)"
  case "$mode" in 700) ;; *) security_fail "credential ledger root must have mode 0700: $keys_root (mode ${mode:-?})" ;; esac
  for identity in "$keys_root"/identity/age.txt "$keys_root"/identity/signing_ed25519; do
    [ -e "$identity" ] || continue
    [ ! -L "$identity" ] || { security_fail "key identity must not be a symlink: $identity"; continue; }
    [ "$(stat -c '%a' "$identity" 2>/dev/null || true)" = 600 ] \
      || security_fail "key identity must have mode 0600: $identity"
  done
fi

# Live checks are conditional for host-free CI, mandatory after `yard init`.
live=0
if [ "${SUBYARD_SECURITY_SKIP_LIVE:-0}" != 1 ] \
  && command -v incus >/dev/null 2>&1 \
  && incus info >/dev/null 2>&1 \
  && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; then
  live=1
fi
if [ "$live" = 0 ]; then
  [ "$require_live" = 0 ] || security_fail "live Incus project '$INCUS_PROJECT' is not reachable"
  security_warn "live Incus state unavailable; static contract checked only"
else
  [ "$(incus project get "$INCUS_PROJECT" restricted 2>/dev/null || true)" = true ] \
    || security_fail "Incus project '$INCUS_PROJECT' is not restricted"
  [ "$(incus project get "$INCUS_PROJECT" restricted.containers.privilege 2>/dev/null || true)" = unprivileged ] \
    || security_fail "Incus project '$INCUS_PROJECT' does not require unprivileged containers"
  want_interception=block
  [ "${NESTED_E2E_VMS:-0}" = 0 ] || want_interception=allow
  [ "$(incus project get "$INCUS_PROJECT" restricted.containers.interception 2>/dev/null || true)" = "$want_interception" ] \
    || security_fail "Incus project '$INCUS_PROJECT' syscall interception policy does not match NESTED_E2E_VMS"

  if incus info "$INSTANCE_NAME" --project "$INCUS_PROJECT" >/dev/null 2>&1; then
    [ "$(incus config get "$INSTANCE_NAME" security.privileged --project "$INCUS_PROJECT" 2>/dev/null || true)" != true ] \
      || security_fail "instance '$INSTANCE_NAME' is privileged"
    while IFS= read -r device; do
      [ -n "$device" ] || continue
      type="$(incus config device get "$INSTANCE_NAME" "$device" type --expanded --project "$INCUS_PROJECT" 2>/dev/null || true)"
      source="$(incus config device get "$INSTANCE_NAME" "$device" source --expanded --project "$INCUS_PROJECT" 2>/dev/null || true)"
      path="$(incus config device get "$INSTANCE_NAME" "$device" path --expanded --project "$INCUS_PROJECT" 2>/dev/null || true)"
      listen="$(incus config device get "$INSTANCE_NAME" "$device" listen --expanded --project "$INCUS_PROJECT" 2>/dev/null || true)"
      case "${source,,} ${path,,}" in
        *docker.sock* | *incus.sock* | *lxd.sock*) security_fail "device '$device' exposes a host-control socket" ;;
      esac
      if [ "$type" = disk ] && [[ "$source" == /* ]]; then
        case "$device" in
          host-* | yx-*)
            path_is_within "$source" "$HOST_BASE" \
              || security_fail "managed disk device '$device' is outside HOST_BASE: $source" ;;
          *)
            path_is_within "$source" "$HOST_BASE" \
              || security_warn "explicit disk device '$device' exposes host path '$source'; encapsulation is reduced" ;;
        esac
      fi
      if [ "$type" = unix-char ]; then
        case "$source" in
          /dev/kvm | /dev/fuse | /dev/dri/renderD[0-9]*) ;;
          /dev/vsock | /dev/vhost-vsock | /dev/net/tun)
            [ "${NESTED_E2E_VMS:-0}" = 1 ] \
              || security_fail "nested VM device '$device' is attached while NESTED_E2E_VMS is disabled" ;;
          *) security_fail "unix-char device '$device' is outside the supported device allowlist: ${source:-unset}" ;;
        esac
      fi
      if [ "$type" = proxy ]; then
        case "$listen" in
          tcp:127.0.0.1:* | udp:127.0.0.1:* | 'tcp:[::1]:'* | 'udp:[::1]:'*) ;;
          *) security_fail "proxy device '$device' is not loopback-only: ${listen:-unset}" ;;
        esac
      fi
    done < <(incus config device list "$INSTANCE_NAME" --expanded --project "$INCUS_PROJECT" 2>/dev/null)
    bpf="$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf --project "$INCUS_PROJECT" 2>/dev/null || true)"
    bpf_devices="$(incus config get "$INSTANCE_NAME" security.syscalls.intercept.bpf.devices --project "$INCUS_PROJECT" 2>/dev/null || true)"
    if [ "${NESTED_E2E_VMS:-0}" = 1 ]; then
      [ "$bpf" = true ] && [ "$bpf_devices" = true ] \
        || security_fail "nested E2E VMs require both device-cgroup BPF interception flags"
    elif [ -n "$bpf" ] || [ -n "$bpf_devices" ]; then
      security_fail "device-cgroup BPF interception is enabled while NESTED_E2E_VMS is disabled"
    fi
  else
    [ "$require_live" = 0 ] || security_fail "instance '$INSTANCE_NAME' is missing from project '$INCUS_PROJECT'"
    security_warn "instance '$INSTANCE_NAME' is absent; project policy checked only"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf 'Subyard security lint: %s failure(s), %s warning(s)\n' "$failures" "$warnings" >&2
  exit 1
fi
security_ok "Subyard security contract passed ($warnings warning(s))"
