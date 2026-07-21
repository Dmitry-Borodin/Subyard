#!/usr/bin/env bash
# Exact process identity for the in-yard Android Emulator tree.
#
# pgrep/pkill -f see a process's complete argv as one space-separated string. Keep every
# alternative anchored at argv[0] and constrain the executable/launcher path: a command that
# merely mentions emulator-run.sh (ShellCheck, rg, an editor, diagnostics) is not the emulator.

EMU_PROCESS_PATTERN='^(([^[:space:]]*/)?bash[[:space:]]+/tmp/subyard-android/emulator-run\.sh([[:space:]]|$)|([^[:space:]]*/)?cage[[:space:]]+--[[:space:]]+[^[:space:]]*/emulator/emulator([[:space:]]|$)|[^[:space:]]*/emulator/emulator([[:space:]]|$)|[^[:space:]]*/emulator/qemu/[^[:space:]]*/qemu-system-[^[:space:]]+([[:space:]]|$))'

# Pure form used by the host-free regression test; pgrep/pkill use the same POSIX ERE.
emulator_process_cmdline_matches() { # <full-command-line>
  [ "$#" -eq 1 ] || return 2
  printf '%s\n' "$1" | grep -Eq -- "$EMU_PROCESS_PATTERN"
}
