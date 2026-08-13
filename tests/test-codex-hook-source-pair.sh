#!/usr/bin/env bash
# Phase 16 T16-1: Codex repo source ↔ deployed hook F3 pair.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export AIDD_LEDGER_SOURCE=test

SOURCE="$ROOT/hooks/codex/protect-branches-codex.sh"
FIXTURE_DEPLOYED="$TMP_DIR/protect-branches-codex.sh"
cp "$SOURCE" "$FIXTURE_DEPLOYED"

green_out=$(AIDD_CODEX_HOOK_DEPLOYED="$FIXTURE_DEPLOYED" bash "$ROOT/tests/test-pairs-link.sh")
printf '%s\n' "$green_out" | grep -F "pair11 Codex hook MD5 match"

printf '\n# one-side mutation\n' >>"$FIXTURE_DEPLOYED"
set +e
red_out=$(AIDD_CODEX_HOOK_DEPLOYED="$FIXTURE_DEPLOYED" bash "$ROOT/tests/test-pairs-link.sh" 2>&1)
red_rc=$?
set -e

if [[ "$red_rc" -eq 0 ]]; then
  echo "FAIL: one-side mutation did not make pair11 red" >&2
  exit 1
fi
printf '%s\n' "$red_out" | grep -F "pair11 Codex hook MD5 mismatch"
printf '%s\n' "$red_out" | grep -E 'declaration=[0-9a-f]{32} enforcement=[0-9a-f]{32}'
echo "PASS: pair11 one-side mutation is red and prints both MD5 values"
