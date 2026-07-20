#!/usr/bin/env bash
# Regression: `yard code` synchronizes recommended remote extensions to local versions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export SUBYARD_HOME="$TMP/subyard"
export SUBYARD_CONFIG_HOME="$TMP/config"
export SUBYARD_STATE_DIR="$TMP/config/projects"
export SUBYARD_NO_AUDIT=1
export MOCK_INCUS_LOG="$TMP/incus.log"
export MOCK_CODE_LOG="$TMP/code.log"
unset SUBYARD_YARD SUBYARD_YARD_EXPLICIT
mkdir -p "$SUBYARD_STATE_DIR" "$TMP/bin"
cat > "$TMP/bin/incus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  list) printf 'RUNNING\n' ;;
  config)
    [ "${2:-}" = device ] && [ "${3:-}" = list ] && printf 'ssh\n'
    ;;
  exec)
    printf '%s\n' "$*" >> "$MOCK_INCUS_LOG"
    case " $* " in
      *' sh -s -- sync '*)
        printf 'updated:anthropic.claude-code@2.1.209 openai.chatgpt@26.707.91948 sst-dev.opencode@0.0.13\n'
        ;;
    esac
    ;;
  *) exit 90 ;;
esac
SH
cat > "$TMP/bin/code" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CODE_LOG"
case "${1:-}" in
  --list-extensions)
    cat <<'EXT'
ms-vscode-remote.remote-ssh@0.125.0
anthropic.claude-code@2.1.209
openai.chatgpt@26.707.91948
sst-dev.opencode@0.0.13
EXT
    ;;
  --file-uri) exit 0 ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/bin/incus" "$TMP/bin/code"
export PATH="$TMP/bin:$PATH"
cat > "$SUBYARD_STATE_DIR/project-id.json" <<'JSON'
{"schema":1,"projectId":"project-id","name":"Project","hostPath":"/host/Project","yardPath":"/srv/workspaces/project-id/src","mode":"sync","sshHost":"yard","target":"yard"}
JSON

"$ROOT/bin/yard" code Project > "$TMP/out" 2>&1
grep -Fq 'sh -s -- sync anthropic.claude-code@2.1.209 openai.chatgpt@26.707.91948 sst-dev.opencode@0.0.13' "$MOCK_INCUS_LOG" \
  || fail "recommended extension versions were not sent to the yard"
grep -Fxq -- '--list-extensions --show-versions' "$MOCK_CODE_LOG" \
  || fail "local extension versions were not enumerated"
grep -Fxq -- '--file-uri vscode-remote://ssh-remote+yard/home/dev/.subyard/workspaces/Project.code-workspace' "$MOCK_CODE_LOG" \
  || fail "the remote workspace was not opened"
grep -Fq 'remote VS Code extensions matched local versions' "$TMP/out" \
  || fail "successful synchronization was not reported"

# The all-yards list prints qualified selectors when needed. Cross-yard resolution re-execs the
# command in the owning context, where that same selector must still resolve instead of being
# mistaken for the literal project name `strato/Subyard`.
unset SUBYARD_STATE_DIR
mkdir -p "$SUBYARD_CONFIG_HOME/yards/strato/projects"
cat > "$SUBYARD_CONFIG_HOME/yards/strato.env" <<'ENV'
SSH_PORT=2223
ENV
cat > "$SUBYARD_CONFIG_HOME/yards/strato/projects/subyard-id.json" <<'JSON'
{"schema":1,"projectId":"subyard-id","name":"Subyard","hostPath":"/host/Subyard","yardPath":"/srv/workspaces/subyard-id/src","mode":"sync","sshHost":"yard-strato","target":"yard"}
JSON

"$ROOT/bin/yard" code strato/Subyard > "$TMP/qualified.out" 2>&1
grep -Fxq -- '--file-uri vscode-remote://ssh-remote+yard-strato/home/dev/.subyard/workspaces/Subyard.code-workspace' "$MOCK_CODE_LOG" \
  || fail "qualified cross-yard selector did not open the project through the owning yard"

printf 'ok: yard code synchronizes extensions and opens qualified cross-yard selectors\n'
