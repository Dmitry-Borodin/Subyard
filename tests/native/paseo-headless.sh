#!/usr/bin/env bash
# Native, credential-free Paseo acceptance gate for one headless deploy artifact.
set -euo pipefail

ARTIFACT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) [ $# -ge 2 ] || { printf 'test-paseo-headless: --artifact needs a path\n' >&2; exit 2; }; ARTIFACT="$2"; shift 2 ;;
    *) printf 'test-paseo-headless: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -f "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ] \
  || { printf 'test-paseo-headless: regular --artifact is required\n' >&2; exit 2; }
for command in curl git jq ldd readelf sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 \
    || { printf 'test-paseo-headless: %s is required\n' "$command" >&2; exit 2; }
done

case "$(uname -m)" in
  x86_64) expected_arch=amd64; expected_machine='Advanced Micro Devices X86-64'; sdk_platform=linux-x64 ;;
  aarch64|arm64) expected_arch=arm64; expected_machine=AArch64; sdk_platform=linux-arm64 ;;
  *) printf 'test-paseo-headless: unsupported native architecture\n' >&2; exit 2 ;;
esac

temporary="$(mktemp -d /tmp/subyard-paseo-smoke.XXXXXX)"
daemon_launcher=''
print_pid_tree() {
  local pid prefix children child
  pid="$1"
  prefix="$2"
  case "$pid" in
    ''|*[!0-9]*) printf '%sPID unavailable\n' "$prefix" >&2; return ;;
  esac
  if [ ! -r "/proc/$pid/status" ]; then
    printf '%spid=%s gone\n' "$prefix" "$pid" >&2
    return
  fi
  printf '%spid=%s ' "$prefix" "$pid" >&2
  awk '
    $1 == "Name:" { name=$2 }
    $1 == "State:" { state=$2 }
    $1 == "PPid:" { ppid=$2 }
    END { printf "ppid=%s state=%s name=%s\n", ppid, state, name }
  ' "/proc/$pid/status" >&2
  children=''
  IFS= read -r children <"/proc/$pid/task/$pid/children" || true
  for child in $children; do
    print_pid_tree "$child" "$prefix  "
  done
}
print_shutdown_diagnostics() {
  local pid
  printf '\nPaseo daemon log before cleanup:\n' >&2
  tail -n 120 "$temporary/daemon.log" >&2 2>/dev/null || true
  pid="$(jq -r '.pid // empty' "$home/paseo.pid" 2>/dev/null || true)"
  printf '\nPaseo daemon process tree before cleanup:\n' >&2
  print_pid_tree "$pid" '  '
}
cleanup() {
  if [ -n "$daemon_launcher" ] && [ -x "$temporary/artifact/node/bin/node" ]; then
    PASEO_HOME="$temporary/home" "$temporary/artifact/node/bin/node" \
      "$temporary/artifact/app/node_modules/@getpaseo/cli/bin/paseo" \
      daemon stop --home "$temporary/home" --force >/dev/null 2>&1 || true
    wait "$daemon_launcher" 2>/dev/null || true
  fi
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

if tar -tzf "$ARTIFACT" | awk '
  /(^\/|(^|\/)\.\.(\/|$))/ { unsafe=1 }
  END { exit unsafe ? 0 : 1 }
'; then
  printf 'test-paseo-headless: artifact contains an unsafe path\n' >&2
  exit 1
fi
mkdir "$temporary/artifact"
tar -xzf "$ARTIFACT" -C "$temporary/artifact"
artifact="$temporary/artifact"
[ -z "$(find "$artifact" -type l -print -quit)" ] \
  || { printf 'test-paseo-headless: artifact contains a symlink\n' >&2; exit 1; }
jq -e --arg arch "$expected_arch" '
  .schemaVersion == 1 and .kind == "paseo-headless" and
  .paseoVersion == "0.2.1" and .nodeVersion == "22.20.0" and
  .upstreamRevision == "36f38245cab51bbe0b43b6ac42fd41aa757064d9" and
  .os == "linux" and .arch == $arch
' "$artifact/manifest.json" >/dev/null \
  || { printf 'test-paseo-headless: manifest mismatch\n' >&2; exit 1; }
(cd "$artifact" && sha256sum -c files.sha256 >/dev/null)
jq -e --arg arch "$expected_arch" '
  .creationInfo.created == "1970-01-01T00:00:00Z" and
  .documentNamespace ==
    ("https://github.com/Subyard/Subyard/sbom/paseo-headless-0.2.1-linux-" + $arch)
' "$artifact/sbom.spdx.json" >/dev/null \
  || { printf 'test-paseo-headless: SBOM identity is not deterministic\n' >&2; exit 1; }

while IFS= read -r executable; do
  machine="$(readelf -h "$executable" 2>/dev/null \
    | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); print $2}')" || true
  [ "$machine" = "$expected_machine" ] \
    || { printf 'test-paseo-headless: wrong executable architecture: %s\n' "$executable" >&2; exit 1; }
done < <(
  printf '%s\n' "$artifact/node/bin/node"
  find "$artifact/app/node_modules" -type f -name '*.node' -print | sort
)
while IFS= read -r executable; do
  ! ldd "$executable" 2>&1 | grep -q 'not found' \
    || { printf 'test-paseo-headless: unresolved runtime library: %s\n' "$executable" >&2; exit 1; }
done < <(
  printf '%s\n' "$artifact/node/bin/node"
  find "$artifact/app/node_modules" -type f -name '*.node' -print | sort
)

sdk_package="$(find "$artifact/app/node_modules" -type f \
  -path "*/@anthropic-ai/claude-agent-sdk-$sdk_platform/package.json" -print -quit)"
[ -n "$sdk_package" ] && [ "$(jq -r .version "$sdk_package")" = 0.3.214 ] \
  || { printf 'test-paseo-headless: native Claude platform package mismatch\n' >&2; exit 1; }
sdk_executable="$(dirname "$sdk_package")/claude"
[ -x "$sdk_executable" ] \
  || { printf 'test-paseo-headless: native Claude executable is missing\n' >&2; exit 1; }
sdk_machine="$(readelf -h "$sdk_executable" 2>/dev/null \
  | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); print $2}')" || true
[ "$sdk_machine" = "$expected_machine" ] \
  || { printf 'test-paseo-headless: native Claude executable architecture mismatch\n' >&2; exit 1; }

node="$artifact/node/bin/node"
cli="$artifact/app/node_modules/@getpaseo/cli/bin/paseo"
[ "$("$node" --version)" = v22.20.0 ] \
  || { printf 'test-paseo-headless: Node version mismatch\n' >&2; exit 1; }
[ "$("$node" "$cli" --version)" = 0.2.1 ] \
  || { printf 'test-paseo-headless: Paseo version mismatch\n' >&2; exit 1; }
(
  cd "$artifact/app"
  "$node" -e 'import("sherpa-onnx-node").then((module) => { if (!module) process.exit(1); })'
)

home="$temporary/home"
workspaces="$temporary/workspaces"
mkdir -p "$home" "$workspaces/alpha/src" "$workspaces/beta/src"
for id in alpha beta; do
  git -C "$workspaces/$id/src" init -q
  git -C "$workspaces/$id/src" remote add origin https://example.invalid/shared.git
  printf '{"schema":1,"projectId":"%s","name":"%s","mode":"sync"}\n' "$id" "$id" \
    >"$workspaces/$id/.subyard-meta.json"
done
port="$("$node" -e '
  const net = require("node:net");
  const server = net.createServer();
  server.listen(0, "127.0.0.1", () => {
    console.log(server.address().port);
    server.close();
  });
')"
PASEO_HOME="$home" PASEO_RELAY_ENABLED=false PASEO_WEB_UI_ENABLED=false \
PASEO_LOCAL_SPEECH_AUTO_DOWNLOAD=false PASEO_DICTATION_ENABLED=false \
PASEO_VOICE_MODE_ENABLED=false \
  "$node" "$cli" daemon start --foreground --home "$home" \
  --listen "127.0.0.1:$port" --no-relay --no-web-ui \
  >"$temporary/daemon.log" 2>&1 &
daemon_launcher=$!
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$port/api/health" \
  | jq -e '.status == "ok"' >/dev/null

PASEO_HOME="$home" PASEO_WORKSPACE_ROOT="$workspaces" \
PASEO_DAEMON_ENDPOINT="127.0.0.1:$port" \
  "$node" "$artifact/app/libexec/paseo-sync-projects.mjs" --force
PASEO_SMOKE_ROOT="$artifact" PASEO_SMOKE_PORT="$port" \
PASEO_EXPECT_A="$workspaces/alpha/src" PASEO_EXPECT_B="$workspaces/beta/src" \
  "$node" --input-type=module -e '
    import { pathToFileURL } from "node:url";
    const clientModule = process.env.PASEO_SMOKE_ROOT +
      "/app/node_modules/@getpaseo/client/dist/index.js";
    const { createPaseoClient } = await import(pathToFileURL(clientModule).href);
    const client = createPaseoClient({
      url: `ws://127.0.0.1:${process.env.PASEO_SMOKE_PORT}/ws`,
      clientId: "subyard-build-smoke",
      reconnect: { enabled: false },
    });
    await client.connect();
    const result = await client.workspaces.list({ page: { limit: 200 } });
    const expected = new Set([process.env.PASEO_EXPECT_A, process.env.PASEO_EXPECT_B]);
    const entries = result.entries.filter((entry) => expected.has(entry.workspaceDirectory));
    const identities = new Set(entries.map((entry) => entry.projectId));
    if (entries.length !== 2 || identities.size !== 2 ||
        entries.some((entry) => !entry.projectId.startsWith("prj_"))) {
      process.exitCode = 1;
    }
    await client.close();
  '

"$node" -e '
  const pty = require(process.argv[1]);
  const child = pty.spawn("/bin/sh", ["-c", "printf paseo-pty-smoke"], {
    name: "xterm", cols: 80, rows: 24, cwd: "/tmp", env: process.env,
  });
  let output = "";
  child.onData((data) => output += data);
  child.onExit(() => process.exit(output.includes("paseo-pty-smoke") ? 0 : 1));
' "$artifact/app/node_modules/node-pty"

stop_status=0
PASEO_HOME="$home" "$node" "$cli" daemon stop --home "$home" >/dev/null \
  || stop_status=$?
if [ "$stop_status" -ne 0 ]; then
  print_shutdown_diagnostics
  exit "$stop_status"
fi
wait "$daemon_launcher"
daemon_launcher=''
printf 'PASS: native Paseo headless closure (%s)\n' "$expected_arch"
