#!/usr/bin/env sh
# Read-only forced command for the E2E bastion.
set -eu

manifest=${SUBYARD_E2E_ALLOCATION_MANIFEST:-/var/lib/subyard/test-vms-public/allocation.tsv}

if [ -r "$manifest" ]; then
  exec cat "$manifest"
fi

printf 'subyard-e2e-allocation-v1\n'
printf 'state\tdown\n'
printf 'reason\tmanifest-missing\n'
printf 'allocation_id\t0\n'
printf 'expires_at_epoch\t0\n'
