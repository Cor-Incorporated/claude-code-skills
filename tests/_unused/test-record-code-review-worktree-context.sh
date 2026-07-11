#!/usr/bin/env bash
# test-record-code-review-worktree-context.sh -- code-review records use Agent worktree context
set -euo pipefail

PASS=0
FAIL=0
TOTAL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/record-code-review.sh"
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" ]]; then
    git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/worktree" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

json_payload() {
  PROMPT="$1" python3 - <<'PY'
import json, os
print(json.dumps({
    "tool_name": "Agent",
    "tool_input": {
        "subagent_type": "code-reviewer",
        "prompt": os.environ["PROMPT"],
    },
}))
PY
}

state_has_branch() {
  local state_file="$1"
  local branch="$2"
  python3 - "$state_file" "$branch" <<'PY'
import json, sys
path, branch = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
assert data.get(branch, {}).get("code_review") is True
PY
}

echo "=== record-code-review worktree context tests ==="

if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check"
else
  fail "T1: syntax check failed"
fi

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
WT="$TMP_DIR/worktree"
HOME_DIR="$TMP_DIR/home"
PROJECT_DIR="$TMP_DIR/project"
mkdir -p "$HOME_DIR/.claude/state" "$PROJECT_DIR/.claude/state"

git init "$REPO" >/dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
git -C "$REPO" checkout -b develop >/dev/null
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -m "base" >/dev/null

git -C "$REPO" checkout -b opencode/investigation-spikes >/dev/null
printf 'wrong branch\n' > "$REPO/wrong.txt"
git -C "$REPO" add wrong.txt
git -C "$REPO" commit -m "wrong branch" >/dev/null

git -C "$REPO" worktree add -b feat/governance-policy-gate "$WT" develop >/dev/null

payload=$(json_payload "Review branch: feat/governance-policy-gate in worktree: $WT")
out=""
ec=0
out=$(cd "$REPO" && HOME="$HOME_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" <<<"$payload" 2>&1) || ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "T2: hook exits 0 from wrong parent branch"
else
  fail "T2: hook failed (exit $ec: $out)"
fi

if state_has_branch "$HOME_DIR/.claude/state/review-status.json" "feat/governance-policy-gate"; then
  pass "T3: global state uses reviewed worktree branch"
else
  fail "T3: global state missing feat/governance-policy-gate"
fi

if state_has_branch "$PROJECT_DIR/.claude/state/review-status.json" "feat/governance-policy-gate"; then
  pass "T4: CLAUDE_PROJECT_DIR state uses reviewed worktree branch"
else
  fail "T4: project state missing feat/governance-policy-gate"
fi

if state_has_branch "$WT/.claude/state/review-status.json" "feat/governance-policy-gate"; then
  pass "T5: worktree-local state uses reviewed branch"
else
  fail "T5: worktree-local state missing feat/governance-policy-gate"
fi

if python3 - "$HOME_DIR/.claude/state/review-status.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert not data.get("opencode/investigation-spikes", {}).get("code_review")
PY
then
  pass "T6: parent CWD branch was not marked reviewed"
else
  fail "T6: parent CWD branch was incorrectly marked reviewed"
fi

payload=$(python3 - <<PY
import json
print(json.dumps({
    "tool_name": "Agent",
    "tool_input": {
        "subagent_type": "code-reviewer",
        "cwd": "$WT",
        "prompt": "Review this branch",
    },
}))
PY
)
rm -f "$HOME_DIR/.claude/state/review-status.json"
out=$(cd "$REPO" && HOME="$HOME_DIR" bash "$HOOK" <<<"$payload" 2>&1) || ec=$?
if state_has_branch "$HOME_DIR/.claude/state/review-status.json" "feat/governance-policy-gate"; then
  pass "T7: tool_input.cwd resolves branch without prompt branch"
else
  fail "T7: cwd branch resolution failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
