#!/usr/bin/env bash
# Host-free contract for the minimal profile-owned Orca lifecycle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home" SUBYARD_NO_AUDIT=1 PATH="$TMP/bin:$PATH"
export ORCA_TEST_LOG="$TMP/commands.log" ORCA_TEST_ROUTE="$TMP/route"
export ORCA_TEST_CAPTURE="$TMP/capture"
mkdir -p "$HOME" "$TMP/bin" "$ORCA_TEST_CAPTURE"

cat >"$TMP/bin/incus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ORCA_TEST_LOG"
case "${1:-}" in
  info) exit 0 ;;
  list) printf 'RUNNING\n' ;;
  file)
    if [ "${2:-}" = push ]; then
      case "${4:-}" in
        */tmp/subyard-orca-ingress) cp "$3" "$ORCA_TEST_CAPTURE/orca-ingress" ;;
        */tmp/subyard-orca-capture-ready) cp "$3" "$ORCA_TEST_CAPTURE/orca-capture-ready" ;;
        */tmp/subyard-orca-sync) cp "$3" "$ORCA_TEST_CAPTURE/orca-sync" ;;
        */tmp/subyard-orca.service) cp "$3" "$ORCA_TEST_CAPTURE/subyard-orca.service" ;;
      esac
    fi
    ;;
  config)
    case "${2:-} ${3:-}" in
      'device list')
        [ -f "$ORCA_TEST_ROUTE" ] && printf 'orca-server\n'
        ;;
      'device get')
        [ -f "$ORCA_TEST_ROUTE" ] || exit 1
        case "${6:-}" in
          listen) sed -n '1p' "$ORCA_TEST_ROUTE" ;;
          connect) sed -n '2p' "$ORCA_TEST_ROUTE" ;;
        esac
        ;;
      'device add')
        [ "${ORCA_TEST_FAIL_ROUTE:-0}" != 1 ] || exit 1
        listen= connect=
        for argument in "$@"; do
          case "$argument" in
            listen=*) listen="${argument#listen=}" ;;
            connect=*) connect="${argument#connect=}" ;;
          esac
        done
        printf '%s\n%s\n' "$listen" "$connect" > "$ORCA_TEST_ROUTE"
        ;;
      'device remove') rm -f "$ORCA_TEST_ROUTE" ;;
    esac
    ;;
  exec)
    case " $* " in
      *' dpkg --print-architecture '*) printf 'amd64\n' ;;
      *' dpkg-query -W '*orca-ide*) printf '1.4.159\n' ;;
      *' nft list chain inet subyard_orca input '*)
        printf 'chain input { comment "subyard-orca-managed"; }\n'
        ;;
      *' jq -er '*) printf 'orca://pair?code=test-fixture\n' ;;
    esac
    ;;
esac
MOCK

cat >"$TMP/bin/tailscale" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = 'ip -4' ] && printf '100.64.1.20\n'
MOCK

cat >"$TMP/bin/getent" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = ahostsv4 ] && printf '100.64.1.20 STREAM %s\n' "${2:-}"
MOCK

cat >"$TMP/bin/ip" <<'MOCK'
#!/usr/bin/env bash
printf 'tailscale0 UP 100.64.1.20/32\n'
MOCK

cat >"$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ORCA_TEST_LOG"
MOCK
chmod 0755 "$TMP/bin/"*

run_orca() {
  ORCA_ADVERTISE_HOST="${ORCA_TEST_ADVERTISE:-owner.example-tailnet.ts.net}" \
    ORCA_HOST_PORT=17678 "$ROOT/bin/yard" orca "$@"
}

run_orca up --yes >"$TMP/up.out"
grep -Fxq 'tcp:100.64.1.20:17678' "$ORCA_TEST_ROUTE" \
  || fail 'Tailscale mode did not bind the exact owner address'
grep -Fxq 'tcp:127.0.0.1:6768' "$ORCA_TEST_ROUTE" \
  || fail 'owner route did not target yard loopback'
grep -Fq 'ExecStart=/usr/local/libexec/subyard/orca-capture-ready' \
  "$ORCA_TEST_CAPTURE/subyard-orca.service" \
  || fail 'service does not isolate readiness JSON'
grep -Fq 'ExecStart=/usr/local/libexec/subyard/orca-capture-ready /srv/agents/orca/ready.json /usr/bin/orca-ide serve' \
  "$ORCA_TEST_CAPTURE/subyard-orca.service" \
  || fail 'service does not use the packaged Orca CLI'
grep -Fq -- '--pairing-address owner.example-tailnet.ts.net:17678 --json' \
  "$ORCA_TEST_CAPTURE/subyard-orca.service" \
  || fail 'service does not advertise the owner endpoint'
if grep -Fq -- '--no-pairing' "$ORCA_TEST_CAPTURE/subyard-orca.service"; then
  fail 'service disabled stock startup pairing'
fi
grep -Fq '.result.repos[]?' "$ORCA_TEST_CAPTURE/orca-sync" \
  || fail 'project hook does not use the stock repo list contract'
grep -Fq 'repo add --path "$checkout" --json' "$ORCA_TEST_CAPTURE/orca-sync" \
  || fail 'project hook does not add canonical roots'
if grep -Eqi 'nodejs|npm|AppImage|squashfs|APPDIR|SHA512' \
  "$ROOT/config/profiles/orca/resources/orca/handler.sh" "$ROOT/config/profiles/orca/release.env"; then
  fail 'removed SSH/AppImage dependencies returned'
fi

pairing="$(run_orca pair --yes | tail -n1)"
[ "$pairing" = 'orca://pair?code=test-fixture' ] \
  || fail 'pair did not return only the stock startup link'
grep -Fq 'systemctl restart subyard-orca.service' "$ORCA_TEST_LOG" \
  || fail 'pair did not mint a fresh startup offer'
run_orca sync >/dev/null
grep -Fq 'runuser -u dev -- /usr/local/libexec/subyard/projects-changed.d/orca' "$ORCA_TEST_LOG" \
  || fail 'sync did not invoke the resource-owned project hook as dev'

ORCA_TEST_ADVERTISE=127.0.0.1 run_orca up --yes >/dev/null
grep -Fxq 'tcp:127.0.0.1:17678' "$ORCA_TEST_ROUTE" \
  || fail 'SSH mode was not limited to owner loopback'

run_orca down --yes >/dev/null
[ ! -e "$ORCA_TEST_ROUTE" ] || fail 'down left the owned route attached'
grep -Fq 'systemctl disable --now subyard-orca.service' "$ORCA_TEST_LOG" \
  || fail 'down did not stop the profile-owned service'

if ORCA_ADVERTISE_HOST='https://bad/path' ORCA_HOST_PORT=17678 \
  "$ROOT/bin/yard" orca up --yes >"$TMP/invalid.out" 2>&1; then
  fail 'unsafe advertised hostname was accepted'
fi
grep -Fq 'without scheme, path or port' "$TMP/invalid.out" \
  || fail 'unsafe hostname failure was not actionable'

grep -Fq 'projects-changed.d/*' "$ROOT/scripts/04-provision-subyard.sh" \
  || fail 'project lifecycle dispatcher does not include shared-resource hooks'

printf 'ok: Orca uses stock pairing, project sync and exact Tailscale/SSH owner routes\n'
