#!/bin/bash
# test-task-completion-comment-set-hash.sh — TaskCompleted stale review-state guard

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/task-completion-gate.sh"
TMP_ROOT="$(mktemp -d)"
TMP_HOME="$TMP_ROOT/home"
TMP_REPO="$TMP_ROOT/repo"
TMP_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_REPO/.claude/state"
PENDING_FILE="$STATE_DIR/pending-review-comments.json"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_HOME" "$TMP_BIN" "$STATE_DIR"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# test\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" branch -M feature
git -C "$TMP_REPO" remote add origin https://github.com/owner/repo.git

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '123\n'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf 'abc123\n'
    exit 0
  fi
  printf '{"head":{"sha":"abc123"}}\n'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/commits/abc123/check-runs" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf '0\n'
  else
    printf '{"check_runs":[]}\n'
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/comments" ]; then
  cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"No high findings.\n[HIGH] historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"}
]
JSON
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/issues/123/comments" ]; then
  cat <<'JSON'
[
  {"id":201,"body":"No critical findings.\n[CRITICAL] historical heading only","user":{"login":"claude[bot]"},"updated_at":"2026-06-06T00:01:00Z"}
]
JSON
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/reviews" ]; then
  printf '[]\n'
  exit 0
fi
exit 1
FAKEGH
chmod +x "$TMP_BIN/gh"

PASSED=0
FAILED=0
TOTAL=0

calc_hash() {
  PATH="$TMP_BIN:$PATH" bash "$ROOT/scripts/review-comment-set-hash.sh" 123 owner/repo abc123
}

write_pending() {
  local hash="$1"
  local include_hash="${2:-yes}"
  HASH="$hash" INCLUDE_HASH="$include_hash" PENDING_FILE="$PENDING_FILE" python3 - <<'PY'
import json
import os

state = {
    "pr": "123",
    "repo": "owner/repo",
    "head_sha": "abc123",
    "total": 2,
    "critical": 0,
    "high": 0,
    "classification_method": "ai",
    "ai_classification": {"critical": 0, "high": 0},
}
if os.environ["INCLUDE_HASH"] == "yes":
    state["comment_set_hash"] = os.environ["HASH"]
with open(os.environ["PENDING_FILE"], "w") as f:
    json.dump(state, f)
PY
}

run_hook() {
  local payload='{"task_subject":"merge PR","task_id":"t1"}'
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" \
      bash "$HOOK" <<<"$payload"
  )
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  set +e
  run_hook >/tmp/task_completion_hash_test.out 2>/tmp/task_completion_hash_test.err
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit $expected, got $rc)" >&2
    cat /tmp/task_completion_hash_test.err >&2 || true
  fi
}

echo "=== task-completion comment_set_hash enforcement ==="

GOOD_HASH="$(calc_hash)"
write_pending "$GOOD_HASH"
expect_rc "T1: matching comment_set_hash allows completion" 0

write_pending "stale"
expect_rc "T2: stale comment_set_hash blocks completion" 2

write_pending "$GOOD_HASH" no
expect_rc "T3: missing comment_set_hash blocks completion" 2

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
rm -f /tmp/task_completion_hash_test.out /tmp/task_completion_hash_test.err
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
