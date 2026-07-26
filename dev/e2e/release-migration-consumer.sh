#!/usr/bin/env bash
# Standard broker client proof inside the pre-existing catch-up consumer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ "${SUBYARD_E2E_CONSUMER_FIXTURE:-0}" = 1 ] \
  || { printf 'release-migration-consumer: fixture confirmation is required\n' >&2; exit 2; }
[ -r /var/lib/subyard/e2e-routes/test-yard/current/route.tsv ] \
  && [ -r /var/lib/subyard/e2e-routes/test-yard/current/known_hosts ] \
  || { printf 'release-migration-consumer: canonical route is unavailable\n' >&2; exit 2; }

cd "$ROOT"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q
  git config user.name fixture
  git config user.email fixture@example.invalid
  git add -A
  git commit -qm fixture
fi

dev/agent-e2e.sh --prepare
dev/agent-e2e.sh --wait 20m --vm both -- sh -c \
  'printf "hostname=%s uid=%s sudo=%s\n" "$(hostname)" "$(id -u)" "$(sudo -n id -u)"'
dev/agent-e2e.sh --verify-boundary
