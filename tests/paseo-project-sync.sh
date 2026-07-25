#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/config/agents/paseo/sync-projects.mjs"
TEMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TEMP"; }
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

workspace_root="$TEMP/workspaces"
paseo_home="$TEMP/paseo-home"
log="$TEMP/client.jsonl"
mkdir -p "$workspace_root" "$paseo_home"

write_project() {
  local id="$1"
  mkdir -p "$workspace_root/$id/src"
  printf '{"schema":1,"projectId":"%s","name":"%s","mode":"sync","remote":"same"}\n' \
    "$id" "$id" >"$workspace_root/$id/.subyard-meta.json"
}
write_project alpha
write_project beta
write_project gamma
mkdir -p "$workspace_root/escape"
printf '{"schema":1,"projectId":"escape","name":"escape","mode":"sync"}\n' \
  >"$workspace_root/escape/.subyard-meta.json"
ln -s "$TEMP" "$workspace_root/escape/src"
printf '{"schema":1,"projectId":"../bad","name":"bad","mode":"sync"}\n' \
  >"$workspace_root/bad.json"

fake="$TEMP/fake-client.mjs"
cat >"$fake" <<'JS'
import { appendFile } from "node:fs/promises";

const log = async (entry) => {
  await appendFile(process.env.PASEO_FAKE_LOG, `${JSON.stringify(entry)}\n`);
};

if (process.env.PASEO_FAKE_FAIL_ON_LOAD === "1") {
  throw new Error("client module should not have loaded");
}

export function createPaseoClient(config) {
  let page = 0;
  return {
    connect: async () => log({ event: "connect", url: config.url }),
    close: async () => log({ event: "close" }),
    workspaces: {
      list: async (options) => {
        await log({ event: "list", page: page, cursor: options.page.cursor ?? null });
        if (process.env.PASEO_FAKE_MODE === "unstable") {
          page += 1;
          return { entries: [], emptyProjects: [], pageInfo: {
            hasMore: true, nextCursor: "repeat", prevCursor: null,
          } };
        }
        if (page++ === 0) {
          return {
            entries: [{ workspaceDirectory: process.env.PASEO_FAKE_ACTIVE }],
            emptyProjects: [{ projectRootPath: process.env.PASEO_FAKE_EMPTY_PROJECT }],
            pageInfo: { hasMore: true, nextCursor: "page-2", prevCursor: null },
          };
        }
        return {
          entries: [],
          emptyProjects: [],
          pageInfo: { hasMore: false, nextCursor: null, prevCursor: "page-1" },
        };
      },
      open: async ({ cwd }) => {
        await log({ event: "open", cwd });
        return {
          requestId: "open",
          workspace: { id: `ws_${cwd.split("/").at(-2)}`, projectId: "prj_0123456789abcdef" },
          error: null,
        };
      },
    },
  };
}
JS

run_sync() {
  PASEO_WORKSPACE_ROOT="$workspace_root" \
  PASEO_HOME="$paseo_home" \
  PASEO_DAEMON_ENDPOINT=127.0.0.1:6767 \
  PASEO_SYNC_CLIENT_MODULE="file://$fake" \
  PASEO_FAKE_LOG="$log" \
  PASEO_FAKE_ACTIVE="$workspace_root/alpha/src" \
  PASEO_FAKE_EMPTY_PROJECT="$workspace_root/beta/src" \
    node "$HELPER" "$@"
}

run_sync --force
[ "$(jq -r 'select(.event == "open") | .cwd' "$log")" = "$workspace_root/gamma/src" ] \
  || fail "fresh sync did not open only the missing exact root"
[ "$(jq -s '[.[] | select(.event == "list")] | length' "$log")" -eq 2 ] \
  || fail "workspace pagination was not consumed"
jq -e --arg alpha "$workspace_root/alpha/src" --arg beta "$workspace_root/beta/src" \
  --arg gamma "$workspace_root/gamma/src" '
    .schemaVersion == 1 and
    .projects == {alpha: $alpha, beta: $beta, gamma: $gamma}
  ' "$paseo_home/seen-projects.json" >/dev/null || fail "seen-projects cache is wrong"

before="$(wc -l <"$log")"
PASEO_FAKE_FAIL_ON_LOAD=1 run_sync
[ "$(wc -l <"$log")" -eq "$before" ] || fail "unchanged fingerprint opened a WebSocket"

: >"$log"
run_sync --force
[ "$(jq -s '[.[] | select(.event == "open")] | length' "$log")" -eq 0 ] \
  || fail "repeat sync reopened a seen archived workspace"

rm -rf -- "$workspace_root/alpha"
: >"$log"
run_sync --force
jq -e '(.projects | has("alpha") | not) and
  (.projects | keys == ["beta", "gamma"])' "$paseo_home/seen-projects.json" >/dev/null \
  || fail "removed inventory entry was not pruned from the disposable cache"
[ "$(jq -s '[.[] | select(.event == "archive" or .event == "delete")] | length' "$log")" -eq 0 ] \
  || fail "sync performed destructive cleanup"

printf '{broken\n' >"$paseo_home/seen-projects.json"
printf 'broken\n' >"$paseo_home/subyard-projects.fingerprint"
: >"$log"
run_sync
[ "$(jq -s '[.[] | select(.event == "open")] | length' "$log")" -eq 1 ] \
  || fail "corrupt disposable cache did not recover additively"

rm -f "$paseo_home/subyard-projects.fingerprint"
: >"$log"
if PASEO_FAKE_MODE=unstable run_sync --force; then
  fail "unstable pagination was accepted"
fi
[ ! -e "$paseo_home/subyard-projects.fingerprint" ] \
  || fail "failed sync advanced the fingerprint"

printf 'PASS: Paseo project discovery is exact-root, additive and cache-safe\n'
