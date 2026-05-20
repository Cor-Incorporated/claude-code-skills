#!/usr/bin/env bash
# test-publish-preflight-scenario.sh — end-to-end preflight scenario for publish flow
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SUBAGENT="$ROOT/hooks/block-subagent-github-write.sh"
HOOK_FACTCHECK="$ROOT/hooks/enforce-factcheck-github-ops.sh"
HOOK_PRECREATE="$ROOT/hooks/pr-ci-review-gate.sh"
HOOK_PR_GUARD="$ROOT/hooks/pr-guard.sh"
HOOK_DEPLOY="$ROOT/hooks/enforce-deploy-verify-on-pr.sh"

TMP_HOME=""
TMP_PROJECT=""
cleanup() {
  [[ -n "$TMP_HOME" ]] && rm -rf "$TMP_HOME"
  [[ -n "$TMP_PROJECT" ]] && rm -rf "$TMP_PROJECT"
}
trap cleanup EXIT

echo "=== Publish preflight scenario tests ==="

for hook in "$HOOK_SUBAGENT" "$HOOK_FACTCHECK" "$HOOK_PRECREATE" "$HOOK_PR_GUARD" "$HOOK_DEPLOY"; do
  if bash -n "$hook" 2>/dev/null; then
    pass "syntax check: $(basename "$hook")"
  else
    fail "syntax check failed: $(basename "$hook")"
  fi
done

TMP_HOME=$(mktemp -d)
TMP_PROJECT=$(mktemp -d)
mkdir -p "$TMP_HOME/.claude/hooks" "$TMP_HOME/.claude/scripts" "$TMP_HOME/.claude/state" "$TMP_PROJECT/.claude/state"

# Deploy current hooks/scripts into temp HOME to satisfy deploy verification.
cp "$ROOT"/hooks/*.sh "$TMP_HOME/.claude/hooks/"
cp "$ROOT"/scripts/*.sh "$TMP_HOME/.claude/scripts/"

BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
# CI (GitHub Actions) checks out a detached HEAD for PR builds.
# GITHUB_HEAD_REF carries the PR source branch name in that context.
if [[ -z "$BRANCH" ]]; then
  BRANCH="${GITHUB_HEAD_REF:-}"
fi
# Final fallback: any non-empty name is fine since this test only needs
# a branch key to seed review-status.json and exercise hook logic.
if [[ -z "$BRANCH" ]]; then
  BRANCH="ci-test-branch"
fi

cat > "$TMP_HOME/.claude/state/factcheck-status.json" <<EOF
{"factchecked": true, "timestamp": $(date +%s), "source": "scenario-test", "edit_count_since_check": 0}
EOF

cat > "$TMP_HOME/.claude/state/review-status.json" <<EOF
{
  "$BRANCH": {
    "code_review": true,
    "codex_review": true
  }
}
EOF

payload='{"tool_name":"Bash","tool_input":{"command":"gh pr create --base develop --title \"fix: publish path\" --body \"## Summary\nCloses #220\n- scenario\""}}'

run_hook() {
  local hook="$1"
  local label="$2"
  local extra_env=("${@:3}")
  local ec=0
  if out=$(cd "$ROOT" && env HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PROJECT" "${extra_env[@]}" bash "$hook" <<<"$payload" 2>&1); then
    if [[ -z "$out" || "$out" == *"[PR Guard] 確認事項:"* ]]; then
      pass "$label"
    else
      fail "$label (unexpected output: $out)"
    fi
  else
    ec=$?
    fail "$label (exit $ec: $out)"
  fi
}

run_hook "$HOOK_SUBAGENT" "T6: parent publish command bypasses subagent guard"
run_hook "$HOOK_FACTCHECK" "T7: factchecked PR body passes GitHub factcheck guard"
run_hook "$HOOK_PRECREATE" "T8: PRE_CREATE passes when review pipeline is satisfied" GATE_MODE=PRE_CREATE
run_hook "$HOOK_PR_GUARD" "T9: pr-guard accepts base+Closes issue reference"
run_hook "$HOOK_DEPLOY" "T10: deploy verification passes when temp deployment is in sync"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
