#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

# Intentionally divergent same-name modules: lib/findings.mjs and lib/quota.mjs.
# Do not add them here merely because both variants contain those filenames.

if ! cmp -s "$ROOT/LICENSE" "$ROOT/sleep-well/LICENSE" \
  || ! cmp -s "$ROOT/LICENSE" "$ROOT/sleep-well-codex/LICENSE"; then
  printf 'license copy mismatch\n' >&2
  FAILED=1
fi

for rel in \
  lib/backup.mjs \
  lib/config.mjs \
  lib/guardrails.mjs \
  lib/queue.mjs \
  lib/report.mjs \
  lib/reviewLoop.mjs \
  lib/state.mjs \
  test/backup.test.mjs \
  test/config.test.mjs \
  test/guardrails.test.mjs \
  test/queue.test.mjs \
  test/report.test.mjs \
  test/reviewLoop.test.mjs \
  test/state.test.mjs
do
  if ! cmp -s "$ROOT/sleep-well/$rel" "$ROOT/sleep-well-codex/$rel"; then
    printf 'shared-file mismatch: %s\n' "$rel" >&2
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

printf 'shared module parity: OK\n'
