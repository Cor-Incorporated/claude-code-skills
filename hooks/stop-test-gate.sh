#!/bin/bash
# stop-test-gate.sh — Stop hook: run change-related test gate before session end
# ====================================================================
# Issue #66 Fix #3: stop_hook_active check added (official docs compliance)
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: Stop (no matcher support)
#   stdin: { stop_hook_active: bool, last_assistant_message: string }
#   Exit 2 = prevent Claude from stopping (continue working)
#   Exit 0 = allow stop
#
# Logic:
#   1. Check stop_hook_active to prevent infinite loops
#   2. Skip if dirty tree (active error recovery — Issue #58)
#   3. Detect project test framework
#   4. Detect and classify changed files (ADR-003 Phase 1)
#   5. Skip docs/config-only changes, otherwise run test gate
#   6. On failure, block stop and show test output
# ====================================================================

set -uo pipefail
# Note: -e is intentionally omitted because timeout returns non-zero

# =========================================================================
# Read stdin and check stop_hook_active (MUST be first check)
# Ref: "To prevent Claude Code from running indefinitely,
#       check stop_hook_active or analyze the transcript."
# =========================================================================
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

if [[ -n "$input" ]] && command -v jq &>/dev/null; then
  _stop_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  if [[ "$_stop_active" == "true" ]]; then
    # Already continuing from a previous Stop hook — don't block again
    echo "[stop-test-gate] stop_hook_active=true: 2回目のStop。テストスキップ。" >&2
    exit 0
  fi
fi

# =========================================================================
# Issue #58: Skip gate during active error recovery
# If the working tree has unstaged changes, the developer is actively working.
# Blocking the session end during error recovery breaks autonomous fix loops.
# =========================================================================
if git diff --quiet HEAD 2>/dev/null; then
  : # Clean tree — proceed with test gate
else
  # Dirty tree — active work in progress, skip gate
  exit 0
fi

# =========================================================================
# Determine project root
# =========================================================================
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
elif git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_DIR="$(git rev-parse --show-toplevel)"
else
  PROJECT_DIR="$PWD"
fi

# =========================================================================
# ADR-003 Phase 1: change-related file detection
# =========================================================================
TEST_FILE_REGEX='(_test\.(go|py|ts|tsx|js|jsx)|\.test\.(ts|tsx|js|jsx)|\.spec\.(ts|tsx|js|jsx)|test_[a-z].*\.py|/__tests__/)'
NON_TESTABLE_REGEX='\.(md|yml|yaml|css|scss|svg|png|jpg|gif|ico|lock|txt|rst)$|^\.github/|^\.claude/|^docs/|^\.vscode/|^\.idea/'
CROSS_CUTTING_SOURCE_THRESHOLD=20

detect_changed_files() {
  local base=""

  if base=$(git merge-base HEAD develop 2>/dev/null); then
    :
  elif base=$(git merge-base HEAD main 2>/dev/null); then
    :
  elif git rev-parse --verify HEAD~10 >/dev/null 2>&1; then
    base=$(git rev-parse HEAD~10)
  elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    base=$(git rev-parse HEAD~1)
  fi

  [[ -z "$base" ]] && { echo "[stop-test-gate] merge-base 未解決: full suite fallback。" >&2; return 1; }

  git diff --name-only "$base"..HEAD 2>/dev/null
}

classify_files() {
  local file=""

  TEST_FILES=()
  SOURCE_FILES=()
  NON_TESTABLE_FILES=()

  for file in "$@"; do
    [[ -z "$file" ]] && continue

    if printf '%s\n' "$file" | grep -Eq "$NON_TESTABLE_REGEX"; then
      NON_TESTABLE_FILES+=("$file")
    elif printf '%s\n' "$file" | grep -Eq "$TEST_FILE_REGEX"; then
      TEST_FILES+=("$file")
    else
      SOURCE_FILES+=("$file")
    fi
  done
}

# =========================================================================
# Test detection logic (priority order)
# =========================================================================
TEST_CMD=""

if [ -f "$PROJECT_DIR/package.json" ] && command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
  # Node.js project with test script
  if [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
    TEST_CMD="cd \"$PROJECT_DIR\" && pnpm test"
  elif [ -f "$PROJECT_DIR/yarn.lock" ]; then
    TEST_CMD="cd \"$PROJECT_DIR\" && yarn test"
  else
    TEST_CMD="cd \"$PROJECT_DIR\" && npm test"
  fi
elif [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/setup.py" ]; then
  if command -v pytest >/dev/null 2>&1; then
    TEST_CMD="cd \"$PROJECT_DIR\" && pytest --tb=short -q"
  elif [ -d "$PROJECT_DIR/tests" ]; then
    TEST_CMD="cd \"$PROJECT_DIR\" && python3 -m pytest --tb=short -q"
  fi
elif [ -f "$PROJECT_DIR/go.mod" ]; then
  TEST_CMD="cd \"$PROJECT_DIR\" && go test ./... -count=1 -short"
elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  TEST_CMD="cd \"$PROJECT_DIR\" && cargo test"
elif [ -f "$PROJECT_DIR/Makefile" ] && grep -q '^test:' "$PROJECT_DIR/Makefile"; then
  TEST_CMD="cd \"$PROJECT_DIR\" && make test"
fi

# No test framework detected — allow stop
if [ -z "$TEST_CMD" ]; then
  exit 0
fi

CHANGED_FILES=()
_detect_exit=0
while IFS= read -r changed_file; do
  [[ -n "$changed_file" ]] && CHANGED_FILES+=("$changed_file")
done < <(detect_changed_files) || _detect_exit=$?

if [[ "$_detect_exit" -ne 0 ]]; then
  echo "[stop-test-gate] merge-base解決失敗: full suite fallback。" >&2
  # Fall through to full suite execution (skip classification)
elif [[ "${#CHANGED_FILES[@]}" -eq 0 ]]; then
  echo "[stop-test-gate] 変更ファイル未検出: テスト不要。" >&2
  exit 0
fi

if [[ "$_detect_exit" -eq 0 ]] && [[ "${#CHANGED_FILES[@]}" -gt 0 ]]; then
  TEST_FILES=()
  SOURCE_FILES=()
  NON_TESTABLE_FILES=()
  classify_files "${CHANGED_FILES[@]}"

  if [[ "${#NON_TESTABLE_FILES[@]}" -eq "${#CHANGED_FILES[@]}" ]]; then
  echo "[stop-test-gate] docs/config-only 変更: テスト不要。" >&2
  exit 0
fi

if [[ "${#SOURCE_FILES[@]}" -ge "$CROSS_CUTTING_SOURCE_THRESHOLD" ]]; then
  echo "[stop-test-gate] source file ${#SOURCE_FILES[@]}件: full suite fallback。" >&2
elif [[ "${#TEST_FILES[@]}" -eq 0 ]]; then
  echo "[stop-test-gate] change-related tests 0件: full suite fallback。" >&2
else
    echo "[stop-test-gate] Phase 1: test file ${#TEST_FILES[@]}件を検出。実行は既存TEST_CMDを維持。" >&2
  fi
fi

# =========================================================================
# Run tests with timeout (60 seconds)
# =========================================================================
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 60"
elif command -v gtimeout >/dev/null 2>&1; then
  # macOS with coreutils installed via Homebrew
  TIMEOUT_CMD="gtimeout 60"
fi

TEST_OUTPUT=""
TEST_EXIT=0
if [ -n "$TIMEOUT_CMD" ]; then
  TEST_OUTPUT=$(_TEST_CMD="$TEST_CMD" $TIMEOUT_CMD bash -c 'eval "$_TEST_CMD"' 2>&1) || TEST_EXIT=$?
else
  # macOS fallback: background process with timer
  _tmp_out="/tmp/stop-test-output.$$"
  _TEST_CMD="$TEST_CMD" bash -c 'eval "$_TEST_CMD"' > "$_tmp_out" 2>&1 &
  _test_pid=$!
  (sleep 60 && kill "$_test_pid" 2>/dev/null) &
  _timer_pid=$!
  wait "$_test_pid" 2>/dev/null
  TEST_EXIT=$?
  kill "$_timer_pid" 2>/dev/null; wait "$_timer_pid" 2>/dev/null || true
  TEST_OUTPUT=$(cat "$_tmp_out" 2>/dev/null)
  rm -f "$_tmp_out"
fi

# Timeout exit code (124 for timeout, 137 for SIGKILL)
if [[ "$TEST_EXIT" -eq 124 ]] || [[ "$TEST_EXIT" -eq 137 ]]; then
  echo "[stop-test-gate] テストがタイムアウト(60秒)。セッション終了を許可。" >&2
  exit 0
fi

# Tests passed
if [[ "$TEST_EXIT" -eq 0 ]]; then
  exit 0
fi

# Tests failed — block stop and show output
TRUNCATED_OUTPUT=$(echo "$TEST_OUTPUT" | tail -30)

# Tests failed — block stop
echo "[stop-test-gate] テスト失敗 (exit=$TEST_EXIT)。修正してください。" >&2
echo "--- テスト出力 (最後の30行) ---" >&2
echo "$TRUNCATED_OUTPUT" >&2
echo "コマンド: $TEST_CMD" >&2
exit 2
