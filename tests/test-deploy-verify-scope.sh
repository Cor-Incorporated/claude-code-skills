#!/usr/bin/env bash
# test-deploy-verify-scope.sh -- deploy drift checks only apply to managed repo assets
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
HOOK="$ROOT/hooks/enforce-deploy-verify-on-pr.sh"
TMP_DIR=""
HOOK_OUT=""
HOOK_EC=0

cleanup() {
  if [[ -n "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

json_payload() {
  CMD="$1" python3 - <<'PY'
import json
import os

print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["CMD"]},
}))
PY
}

setup_repo_with_changed_script() {
  local repo="$1"
  local script_name="$2"
  local remote_url="$3"

  git init "$repo" >/dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" checkout -b develop >/dev/null
  if [[ -n "$remote_url" ]]; then
    git -C "$repo" remote add origin "$remote_url"
  fi

  mkdir -p "$repo/scripts"
  printf '#!/usr/bin/env bash\nprintf "base\\n"\n' > "$repo/scripts/$script_name"
  git -C "$repo" add "scripts/$script_name"
  git -C "$repo" commit -m "base" >/dev/null

  git -C "$repo" checkout -b fix/deploy-scope >/dev/null
  printf '#!/usr/bin/env bash\nprintf "feature\\n"\n' > "$repo/scripts/$script_name"
  git -C "$repo" add "scripts/$script_name"
  git -C "$repo" commit -m "change script" >/dev/null
}

run_hook() {
  local repo="$1"
  local home_dir="$2"
  local command="$3"
  local payload

  payload=$(json_payload "$command")
  HOOK_EC=0
  HOOK_OUT=$(cd "$repo" && HOME="$home_dir" bash "$HOOK" <<<"$payload" 2>&1) || HOOK_EC=$?
}

run_hook_with_override() {
  local repo="$1"
  local home_dir="$2"
  local command="$3"
  local override="$4"
  local payload

  payload=$(json_payload "$command")
  HOOK_EC=0
  HOOK_OUT=$(cd "$repo" && HOME="$home_dir" CLAUDE_CODE_SKILLS_REPO="$override" bash "$HOOK" <<<"$payload" 2>&1) || HOOK_EC=$?
}

expect_exit() {
  local expected="$1"
  local label="$2"

  if [[ "$HOOK_EC" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected exit $expected, got $HOOK_EC: $HOOK_OUT)"
  fi
}

expect_clean_skip_output() {
  local label="$1"

  if [[ -z "$HOOK_OUT" ]]; then
    pass "$label"
  else
    fail "$label (expected silent skip, got: $HOOK_OUT)"
  fi
}

echo "=== deploy verify repo scope tests ==="

TMP_DIR="$(mktemp -d)"
HOME_DIR="$TMP_DIR/home"
mkdir -p "$HOME_DIR/.claude/scripts"

FOREIGN_REPO="$TMP_DIR/foreign"
setup_repo_with_changed_script \
  "$FOREIGN_REPO" \
  "grift-project-script.sh" \
  "git@github.com:Cor-Incorporated/Grift.git"
run_hook "$FOREIGN_REPO" "$HOME_DIR" "gh pr create --base develop --title 'docs: update' --body 'test'"
expect_exit 0 "T1: foreign project-local script drift is ignored"
expect_clean_skip_output "T2: foreign skip is silent"

COLLISION_REPO="$TMP_DIR/collision"
setup_repo_with_changed_script \
  "$COLLISION_REPO" \
  "codex-parallel.sh" \
  "https://github.com/Cor-Incorporated/Grift.git"
printf '#!/usr/bin/env bash\nprintf "deployed-other\\n"\n' > "$HOME_DIR/.claude/scripts/codex-parallel.sh"
run_hook "$COLLISION_REPO" "$HOME_DIR" "gh pr create --base develop --title 'fix: script' --body 'test'"
expect_exit 0 "T3: foreign basename collision is ignored"
expect_clean_skip_output "T4: collision skip is silent"

MANAGED_REPO="$TMP_DIR/managed"
setup_repo_with_changed_script \
  "$MANAGED_REPO" \
  "example.sh" \
  "git@github.com:Cor-Incorporated/claude-code-skills.git"
rm -f "$HOME_DIR/.claude/scripts/example.sh"
run_hook "$MANAGED_REPO" "$HOME_DIR" "gh pr create --base develop --title 'fix: managed' --body 'test'"
expect_exit 2 "T5: managed repo missing deploy is blocked"

run_hook "$MANAGED_REPO" "$HOME_DIR" "gh -R Cor-Incorporated/claude-code-skills pr create --base develop --title 'fix: managed' --body 'test'"
expect_exit 2 "T5b: global -R pr create missing deploy is blocked"

cp "$MANAGED_REPO/scripts/example.sh" "$HOME_DIR/.claude/scripts/example.sh"
run_hook "$MANAGED_REPO" "$HOME_DIR" "gh pr create --base develop --title 'fix: managed' --body 'test'"
expect_exit 0 "T6: managed repo passes after deploy"

MANAGED_WRONG_OVERRIDE_REPO="$TMP_DIR/managed-wrong-override"
setup_repo_with_changed_script \
  "$MANAGED_WRONG_OVERRIDE_REPO" \
  "wrong-override.sh" \
  "git@github.com:Cor-Incorporated/claude-code-skills.git"
run_hook_with_override \
  "$MANAGED_WRONG_OVERRIDE_REPO" \
  "$HOME_DIR" \
  "gh pr create --base develop --title 'fix: managed override' --body 'test'" \
  "git@github.com:Cor-Incorporated/other-repo.git"
expect_exit 2 "T7: managed repo is still blocked when override is wrong"

MANAGED_TRAILING_REPO="$TMP_DIR/managed-trailing"
setup_repo_with_changed_script \
  "$MANAGED_TRAILING_REPO" \
  "trailing.sh" \
  "https://github.com/Cor-Incorporated/claude-code-skills.git/"
run_hook "$MANAGED_TRAILING_REPO" "$HOME_DIR" "gh pr create --base develop --title 'fix: trailing' --body 'test'"
expect_exit 2 "T8: managed repo URL with trailing .git slash is blocked"

FORK_REPO="$TMP_DIR/fork"
setup_repo_with_changed_script \
  "$FORK_REPO" \
  "upstream.sh" \
  "git@github.com:someone/claude-code-skills.git"
git -C "$FORK_REPO" remote add upstream "git@github.com:Cor-Incorporated/claude-code-skills.git"
run_hook "$FORK_REPO" "$HOME_DIR" "gh pr create --base develop --title 'fix: upstream' --body 'test'"
expect_exit 2 "T9: fork with managed upstream is blocked"

PATH_REPO="$TMP_DIR/path-managed"
PATH_WT="$TMP_DIR/path-managed-worktree"
setup_repo_with_changed_script \
  "$PATH_REPO" \
  "path-override.sh" \
  ""
git -C "$PATH_REPO" worktree add --detach "$PATH_WT" fix/deploy-scope >/dev/null
run_hook_with_override \
  "$PATH_WT" \
  "$HOME_DIR" \
  "gh pr create --base develop --title 'fix: path override' --body 'test'" \
  "$PATH_REPO"
expect_exit 2 "T10: path override covers linked worktree"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
