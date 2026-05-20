#!/usr/bin/env bash
# test-pr-create-worktree-context.sh -- PR create hooks honor Bash command worktree context
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
PRECREATE_HOOK="$ROOT/hooks/pr-ci-review-gate.sh"
DEPLOY_HOOK="$ROOT/hooks/enforce-deploy-verify-on-pr.sh"

TMP_DIR=""
cleanup() {
  if [[ -n "$TMP_DIR" ]]; then
    git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/worktree" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

json_payload() {
  CMD="$1" python3 - <<'PY'
import json, os
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["CMD"]},
}))
PY
}

setup_repo() {
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

  mkdir -p "$REPO/hooks/gate-modes"
  printf '# base common\n' > "$REPO/hooks/gate-modes/common.sh"
  git -C "$REPO" add hooks/gate-modes/common.sh
  git -C "$REPO" commit -m "base" >/dev/null

  git -C "$REPO" checkout -b opencode/investigation-spikes >/dev/null
  printf 'side branch\n' > "$REPO/side.txt"
  git -C "$REPO" add side.txt
  git -C "$REPO" commit -m "side" >/dev/null

  git -C "$REPO" worktree add -b feat/worktree-pr "$WT" develop >/dev/null
  printf '# feature common\n' > "$WT/hooks/gate-modes/common.sh"
  git -C "$WT" add hooks/gate-modes/common.sh
  git -C "$WT" commit -m "change gate mode" >/dev/null

  python3 - <<PY
import json
state = {
    "feat/worktree-pr": {
        "code_review": True,
        "codex_review": True,
    }
}
for path in ["$PROJECT_DIR/.claude/state/review-status.json", "$HOME_DIR/.claude/state/review-status.json"]:
    with open(path, "w") as f:
        json.dump(state, f)
PY
}

run_precreate() {
  local cmd="$1"
  local label="$2"
  local payload
  payload=$(json_payload "$cmd")

  local out ec=0
  if out=$(cd "$REPO" && HOME="$HOME_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR" GATE_MODE=PRE_CREATE bash "$PRECREATE_HOOK" <<<"$payload" 2>&1); then
    pass "$label"
  else
    ec=$?
    fail "$label (exit $ec: $out)"
  fi
}

run_deploy_hook_expect() {
  local cmd="$1"
  local expected="$2"
  local label="$3"
  local payload
  payload=$(json_payload "$cmd")

  local out ec=0
  out=$(cd "$REPO" && HOME="$HOME_DIR" bash "$DEPLOY_HOOK" <<<"$payload" 2>&1) || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected exit $expected, got $ec: $out)"
  fi
}

echo "=== PR create worktree context tests ==="

setup_repo

run_precreate \
  "cd $WT && gh pr create --base develop --title 'fix: worktree context' --body 'Closes #999'" \
  "T1: PRE_CREATE uses branch from command cd worktree"

run_precreate \
  $'cd '"$WT"$'\ngh pr create --base develop --title '"'"'fix: worktree context'"'"' --body '"'"'Closes #999'"'" \
  "T2: PRE_CREATE detects multi-line cd then gh pr create"

run_precreate \
  "gh pr create --head feat/worktree-pr --base develop --title 'fix: worktree context' --body 'Closes #999'" \
  "T3: PRE_CREATE uses explicit --head branch"

mkdir -p "$HOME_DIR/.claude/hooks/gate-modes"
printf '# base common\n' > "$HOME_DIR/.claude/hooks/gate-modes/common.sh"
run_deploy_hook_expect \
  "cd $WT && gh pr create --base develop --title 'fix: deploy context' --body 'Closes #999'" \
  2 \
  "T4: deploy verification checks gate-mode file in command worktree"

printf '# feature common\n' > "$HOME_DIR/.claude/hooks/gate-modes/common.sh"
run_deploy_hook_expect \
  "cd $WT && gh pr create --base develop --title 'fix: deploy context' --body 'Closes #999'" \
  0 \
  "T5: deploy verification passes after gate-mode file is deployed"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
