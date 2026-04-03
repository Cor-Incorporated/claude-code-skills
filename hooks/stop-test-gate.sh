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
# CRITICAL: Redirect ALL stdout to stderr.
# Claude Code Stop hooks MUST produce valid JSON or empty stdout.
# Any non-JSON text on stdout causes "JSON validation failed" errors.
# $() captures still work correctly (they create their own pipe for fd 1).
# =========================================================================
exec 1>&2

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

shell_join_args() {
  local arg=""
  local joined=""

  for arg in "$@"; do
    [[ -z "$arg" ]] && continue
    [[ -n "$joined" ]] && joined+=" "
    joined+="$(printf '%q' "$arg")"
  done

  printf '%s' "$joined"
}

resolve_runner_bin() {
  local runner_name="$1"
  local local_bin="$PROJECT_DIR/node_modules/.bin/$runner_name"

  if [[ -x "$local_bin" ]]; then
    printf '%s' "$local_bin"
  elif command -v "$runner_name" >/dev/null 2>&1; then
    command -v "$runner_name"
  fi
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

# =========================================================================
# Issue #217: Monorepo root test guard detection
# Monorepos may intentionally block root-level test execution with a guard
# script (e.g., "echo 'do not run tests from root' && exit 1").
# Detect this pattern and use monorepo-aware test runners instead.
# =========================================================================
if [[ -n "$TEST_CMD" ]] && [[ -f "$PROJECT_DIR/package.json" ]] && command -v jq &>/dev/null; then
  _is_monorepo=false
  if [[ -f "$PROJECT_DIR/turbo.json" ]] || \
     [[ -f "$PROJECT_DIR/pnpm-workspace.yaml" ]] || \
     [[ -f "$PROJECT_DIR/lerna.json" ]] || \
     [[ -f "$PROJECT_DIR/nx.json" ]] || \
     jq -e '.workspaces' "$PROJECT_DIR/package.json" &>/dev/null 2>&1; then
    _is_monorepo=true
  fi

  if [[ "$_is_monorepo" == "true" ]]; then
    _test_script=$(jq -r '.scripts.test // ""' "$PROJECT_DIR/package.json" 2>/dev/null)
    _root_guard=false

    # Guard pattern: explicit exit 1/2 without a known test runner invocation
    if [[ -n "$_test_script" ]]; then
      if echo "$_test_script" | grep -qE 'exit[[:space:]]+[12]'; then
        if ! echo "$_test_script" | grep -qiE '(jest|vitest|mocha|ava|tap|nyc|c8|playwright|cypress|bun[[:space:]]+test)'; then
          _root_guard=true
        fi
      fi
    fi

    # Also check bunfig.toml for explicit test root guard
    if [[ -f "$PROJECT_DIR/bunfig.toml" ]] && grep -q 'do-not-run-tests-from-root' "$PROJECT_DIR/bunfig.toml" 2>/dev/null; then
      _root_guard=true
    fi

    if [[ "$_root_guard" == "true" ]]; then
      echo "[stop-test-gate] monorepo root test guard 検出: 代替テストランナー検索。" >&2
      TEST_CMD=""

      # Priority 1: Turbo (runs test in workspace packages, skips root)
      if [[ -f "$PROJECT_DIR/turbo.json" ]] && command -v turbo &>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && turbo test"
        echo "[stop-test-gate] turbo test を使用。" >&2
      # Priority 2: Nx
      elif [[ -f "$PROJECT_DIR/nx.json" ]] && command -v nx &>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && nx run-many --target=test"
        echo "[stop-test-gate] nx run-many --target=test を使用。" >&2
      # Priority 3: pnpm recursive
      elif [[ -f "$PROJECT_DIR/pnpm-workspace.yaml" ]] && command -v pnpm &>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && pnpm -r test"
        echo "[stop-test-gate] pnpm -r test を使用。" >&2
      # Priority 4: lerna
      elif [[ -f "$PROJECT_DIR/lerna.json" ]] && command -v lerna &>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && lerna run test"
        echo "[stop-test-gate] lerna run test を使用。" >&2
      fi

      if [[ -z "$TEST_CMD" ]]; then
        echo "[stop-test-gate] monorepo test runner 未検出: テストスキップ。" >&2
        exit 0
      fi
    fi
  fi
fi

# No test framework detected — allow stop
if [ -z "$TEST_CMD" ]; then
  exit 0
fi

CHANGED_FILES=()
TEST_FILES=()
SOURCE_FILES=()
NON_TESTABLE_FILES=()
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
# Phase 2: runner-specific targeted test command
# =========================================================================
TARGETED_CMD=""
FULL_SUITE_CMD="$TEST_CMD"

if [[ "$_detect_exit" -eq 0 ]] && [[ "${#SOURCE_FILES[@]}" -gt 0 || "${#TEST_FILES[@]}" -gt 0 ]]; then
  SOURCE_FILES_STR="$(shell_join_args "${SOURCE_FILES[@]}")"
  TEST_FILES_STR="$(shell_join_args "${TEST_FILES[@]}")"

  if [[ -n "$SOURCE_FILES_STR" ]] && { [[ -f "$PROJECT_DIR/vitest.config.ts" ]] || [[ -f "$PROJECT_DIR/vite.config.ts" ]]; }; then
    VITEST_BIN="$(resolve_runner_bin vitest)"
    if [[ -n "$VITEST_BIN" ]]; then
      TARGETED_CMD="cd \"$PROJECT_DIR\" && \"$VITEST_BIN\" run --related ${SOURCE_FILES_STR} --passWithNoTests"
    fi
  fi

  if [[ -z "$TARGETED_CMD" ]] && [[ -n "$SOURCE_FILES_STR" ]] && [[ -f "$PROJECT_DIR/package.json" ]]; then
    JEST_BIN="$(resolve_runner_bin jest)"
    if [[ -n "$JEST_BIN" ]]; then
      TARGETED_CMD="cd \"$PROJECT_DIR\" && \"$JEST_BIN\" --findRelatedTests ${SOURCE_FILES_STR} --passWithNoTests"
    else
      REACT_SCRIPTS_BIN="$(resolve_runner_bin react-scripts)"
      if [[ -n "$REACT_SCRIPTS_BIN" ]]; then
        TARGETED_CMD="cd \"$PROJECT_DIR\" && CI=1 \"$REACT_SCRIPTS_BIN\" test --findRelatedTests ${SOURCE_FILES_STR} --passWithNoTests"
      fi
    fi
  fi

  if [[ -z "$TARGETED_CMD" ]] && [[ -n "$TEST_FILES_STR" ]] && { [[ -f "$PROJECT_DIR/pyproject.toml" ]] || [[ -f "$PROJECT_DIR/setup.py" ]]; }; then
    if command -v pytest >/dev/null 2>&1; then
      TARGETED_CMD="cd \"$PROJECT_DIR\" && pytest ${TEST_FILES_STR} --tb=short -q"
    elif [[ -d "$PROJECT_DIR/tests" ]]; then
      TARGETED_CMD="cd \"$PROJECT_DIR\" && python3 -m pytest ${TEST_FILES_STR} --tb=short -q"
    fi
  fi

  if [[ -z "$TARGETED_CMD" ]] && [[ -f "$PROJECT_DIR/go.mod" ]]; then
    GO_PKGS=()
    GO_PKGS_STR=""

    while IFS= read -r go_pkg; do
      [[ -n "$go_pkg" ]] && GO_PKGS+=("$go_pkg")
    done < <(
      for f in "${SOURCE_FILES[@]}" "${TEST_FILES[@]}"; do
        [[ -z "$f" ]] && continue
        _dir=$(dirname "$f")
        if [[ "$_dir" == "." ]]; then
          printf './...\n'
        else
          printf './%s/...\n' "$_dir"
        fi
      done | sort -u
    )

    GO_PKGS_STR="$(shell_join_args "${GO_PKGS[@]}")"
    if [[ -n "$GO_PKGS_STR" ]]; then
      TARGETED_CMD="cd \"$PROJECT_DIR\" && go test ${GO_PKGS_STR} -count=1 -short"
    fi
  fi
fi

if [[ -n "$TARGETED_CMD" ]]; then
  TEST_CMD="$TARGETED_CMD"
  echo "[stop-test-gate] Phase 2: targeted test command constructed" >&2
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

run_test_command() {
  local command_string="$1"
  local tmp_out=""

  TEST_OUTPUT=""
  TEST_EXIT=0

  if [ -n "$TIMEOUT_CMD" ]; then
    TEST_OUTPUT=$($TIMEOUT_CMD bash -c "$command_string" 2>&1) || TEST_EXIT=$?
  else
    tmp_out=$(mktemp /tmp/stop-test-output.XXXXXX 2>/dev/null || printf '/tmp/stop-test-output.%s' "$$")
    bash -c "$command_string" > "$tmp_out" 2>&1 &
    _test_pid=$!
    (sleep 60 && kill "$_test_pid" 2>/dev/null) &
    _timer_pid=$!
    wait "$_test_pid" 2>/dev/null
    TEST_EXIT=$?
    kill "$_timer_pid" 2>/dev/null; wait "$_timer_pid" 2>/dev/null || true
    TEST_OUTPUT=$(cat "$tmp_out" 2>/dev/null)
    rm -f "$tmp_out"
  fi
}

TEST_OUTPUT=""
TEST_EXIT=0
run_test_command "$TEST_CMD"

if [[ -n "$TARGETED_CMD" ]] && [[ "$TEST_EXIT" -ne 0 ]]; then
  echo "[stop-test-gate] targeted command failed (exit=$TEST_EXIT): full suite fallback。" >&2
  TEST_CMD="$FULL_SUITE_CMD"
  run_test_command "$TEST_CMD"
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
