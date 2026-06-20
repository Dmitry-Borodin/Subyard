#!/usr/bin/env bash
#
# install-cli.sh — put the `yard` command (and `sy` alias) on the operator's PATH.
#
# Symlinks bin/yard into ~/.local/bin and makes sure that directory is on PATH.
# Runs as the operator — NO sudo: it only touches your home (~/.local/bin and,
# if needed, your shell rc). Announces what it will do and asks first (-y skips).
#
# Note: a child process cannot change THIS shell's PATH. After installing, you
# activate the current shell once — the script prints the exact command.
#
# Environment:
#   YARD_BIN_DIR    where to link the command  (default: ~/.local/bin)
#   YARD_SHELL_RC   rc file to update if PATH needs it (default: ~/.bashrc or ~/.zshrc)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
YARD_SRC="$REPO/bin/yard"
BIN_DIR="${YARD_BIN_DIR:-$HOME/.local/bin}"

[ -f "$YARD_SRC" ] || die "yard CLI not found at $YARD_SRC"

# Is BIN_DIR already on PATH?
need_path_line=1
case ":$PATH:" in *":$BIN_DIR:"*) need_path_line=0 ;; esac

# Pick an rc file only if we need to add to PATH.
RC="${YARD_SHELL_RC:-}"
if [ -z "$RC" ]; then
  case "${SHELL:-}" in
    *zsh) RC="$HOME/.zshrc" ;;
    *)    RC="$HOME/.bashrc" ;;
  esac
fi

lines=("Symlink: $BIN_DIR/yard and $BIN_DIR/sy → $YARD_SRC")
if [ "$need_path_line" = 1 ]; then
  lines+=("Add $BIN_DIR to PATH via $RC (it is not on PATH yet).")
else
  lines+=("$BIN_DIR is already on PATH — no shell rc change.")
fi
announce "Install the yard CLI" "${lines[@]}"
proceed_or_die

install -d "$BIN_DIR"
ln -sf "$YARD_SRC" "$BIN_DIR/yard"
ln -sf "$YARD_SRC" "$BIN_DIR/sy"
ok "linked $BIN_DIR/{yard,sy} → bin/yard"

if [ "$need_path_line" = 1 ]; then
  if [ -f "$RC" ] && grep -qF 'Subyard CLI' "$RC"; then
    ok "PATH line already present in $RC"
  else
    printf '\n# Subyard CLI\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$RC"
    ok "added $BIN_DIR to PATH in $RC"
  fi
fi

# --- summary -----------------------------------------------------------------
echo
ok "yard CLI installed."
if [ "$need_path_line" = 1 ]; then
  cat <<MSG

Activate it in THIS shell (a script can't change your current shell's PATH):
  exec "\$SHELL" -l        # or:  source $RC
New shells pick it up automatically. Then try:  yard help
MSG
else
  cat <<'MSG'

Ready — try:  yard help
(if 'yard' is not found yet in this shell, run: hash -r)
MSG
fi
