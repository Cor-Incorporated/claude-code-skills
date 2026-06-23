#!/bin/bash
# test-uat-evidence-hook.sh — UAT/UX/E2E/browser evidence gate

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/enforce-uat-evidence.sh"

PASSED=0
FAILED=0
TOTAL=0

make_input() {
  local command="$1"
  jq -nc --arg command "$command" '{"tool_input":{"command":$command}}'
}

run_hook() {
  local command="$1"
  make_input "$command" | bash "$HOOK" >/tmp/uat_evidence_test.out 2>/tmp/uat_evidence_test.err
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  local command="$3"
  local rc=0

  TOTAL=$((TOTAL + 1))
  set +e
  run_hook "$command"
  rc=$?
  set -e

  if [[ "$rc" -eq "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit $expected, got $rc)" >&2
    echo "  command: $command" >&2
    cat /tmp/uat_evidence_test.err >&2 || true
  fi
}

cleanup() {
  rm -f /tmp/uat_evidence_test.out /tmp/uat_evidence_test.err
}
trap cleanup EXIT

echo "=== UAT evidence hook ==="

expect_rc \
  "T1: no evidence blocks UAT completion issue comment" \
  2 \
  'gh issue comment 123 --body "UAT完了。ブラウザ操作テスト済。Issue close可能です"'

expect_rc \
  "T2: full evidence allows UAT completion issue comment" \
  0 \
  'gh issue comment 123 --body "UAT完了。Evidence: Playwright browser E2E passed. Command: npx playwright test tests/e2e/login.spec.ts (exit 0). URL: https://example.com. Screenshot: artifacts/uat-login.png"'

expect_rc \
  "T3: blocker/unverified issue creation is allowed" \
  0 \
  'gh issue create --title "UAT blocker: ブラウザ未検証" --body "E2E is unverified because login fails; blocker report, not completion."'

expect_rc \
  "T4: non-UAT GitHub write is non-interfering" \
  0 \
  'gh issue comment 123 --body "Docs updated; no runtime claim."'

expect_rc \
  "T5: E2E test command is non-interfering" \
  0 \
  'npm run test:e2e'

expect_rc \
  "T6: completion-like shell claim without evidence blocks" \
  2 \
  'printf "%s\n" "β Ready 完了"'

expect_rc \
  "T7: completion-like shell claim with evidence allows" \
  0 \
  'printf "%s\n" "β Ready 完了。Evidence: Playwright browser E2E passed. Command: npx playwright test tests/e2e/login.spec.ts (exit 0). Screenshot: artifacts/uat-login.png"'

expect_rc \
  "T8: read-only inspection mentioning UAT is non-interfering" \
  0 \
  'rg "UAT完了" docs'

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
