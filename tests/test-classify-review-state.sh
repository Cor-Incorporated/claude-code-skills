#!/bin/bash
# test-classify-review-state.sh — verified updater for /classify-review results

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/classify-review-state.sh"
TMP_ROOT="$(mktemp -d)"
TMP_REPO="$TMP_ROOT/repo"
TMP_BIN="$TMP_ROOT/bin"
STATE_FILE="$TMP_REPO/.claude/state/pending-review-comments.json"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_REPO/.claude/state" "$TMP_BIN"
git -C "$TMP_REPO" init -q

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/sh
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf '%s\n' "${FAKE_HEAD_SHA:-abc123}"
    exit 0
  fi
  printf '{"head":{"sha":"%s"}}\n' "${FAKE_HEAD_SHA:-abc123}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/comments" ]; then
  if [ "${FAKE_UNSAFE_APPROVAL:-0}" = "1" ]; then
    cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"No high findings.\n[HIGH] real auth bypass","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"}
]
JSON
    exit 0
  fi
  if [ "${FAKE_EXTRA_COMMENT:-0}" = "1" ]; then
    cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"HIGH: 0 historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"},
  {"id":102,"commit_id":"abc123","path":"hooks/new.sh","line":20,"body":"[HIGH] new same-head review finding","user":{"login":"bot"},"updated_at":"2026-06-06T00:02:00Z"}
]
JSON
  else
    cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"HIGH: 0 historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"}
]
JSON
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/issues/123/comments" ]; then
  cat <<'JSON'
[
  {"id":201,"body":"CRITICAL: 0 historical heading only","user":{"login":"claude[bot]"},"updated_at":"2026-06-06T00:01:00Z"}
]
JSON
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/reviews" ]; then
  printf '[]\n'
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'owner/repo\n'
  exit 0
fi
exit 1
FAKEGH
chmod +x "$TMP_BIN/gh"

PASSED=0
FAILED=0
TOTAL=0

write_state() {
  (
    cd "$TMP_REPO"
    PATH="$TMP_BIN:$PATH" python3 "$ROOT/hooks/inject-claude-review-helper.py" owner/repo 123 >/dev/null 2>/dev/null
  )
}

verdicts_json() {
  local second_verdict="$1"
  python3 - "$STATE_FILE" "$second_verdict" <<'PY'
import json
import sys

path, second_verdict = sys.argv[1], sys.argv[2]
d = json.load(open(path))
items = []
for idx, verdict in [(0, "false_positive"), (1, second_verdict)]:
    c = d["raw_comments"][idx]
    items.append(
        {
            "index": idx,
            "comment_hash": c["comment_hash"],
            "verdict": verdict,
            "reasoning": "deterministic test verdict",
        }
    )
print(json.dumps(items, separators=(",", ":")))
PY
}

state_value() {
  local expr="$1"
  python3 - "$STATE_FILE" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path))
cur = d
for part in expr.split("."):
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur[part]
print(cur)
PY
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local rc=0
  set +e
  "$@" >/dev/null 2>/dev/null
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit $expected, got exit $rc)" >&2
  fi
}

assert_state() {
  local desc="$1"
  local expr="$2"
  local expected="$3"
  TOTAL=$((TOTAL + 1))
  local actual
  actual="$(state_value "$expr")"
  if [[ "$actual" == "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc ($actual)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected $expected, got $actual)" >&2
  fi
}

run_script() {
  CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" bash "$SCRIPT" "$@"
}

echo "=== classify-review-state updater ==="

write_state
ALL_FALSE="$(verdicts_json false_positive)"
expect_rc "all deterministic false positives unlock gate" 0 run_script 123 "$ALL_FALSE" owner/repo
assert_state "method is ai" "classification_method" "ai"
assert_state "critical cleared" "critical" "0"
assert_state "high cleared" "high" "0"
assert_state "ai critical cleared" "ai_classification.critical" "0"
assert_state "ai high cleared" "ai_classification.high" "0"

write_state
REAL_REMAINS="$(verdicts_json real)"
expect_rc "real keeps gate closed" 2 run_script 123 "$REAL_REMAINS" owner/repo
assert_state "method is ai after real classification" "classification_method" "ai"
assert_state "critical remains for real case" "critical" "1"
assert_state "high removed for real case" "high" "0"
assert_state "real verdict persisted" "ai_classification.verdicts.1.verdict" "real"

write_state
UNKNOWN_REMAINS="$(verdicts_json unknown)"
expect_rc "unknown keeps gate closed" 2 run_script 123 "$UNKNOWN_REMAINS" owner/repo
assert_state "method is ai after unknown classification" "classification_method" "ai"
assert_state "critical remains for unknown case" "critical" "1"
assert_state "high removed for unknown case" "high" "0"
assert_state "unknown verdict persisted" "ai_classification.verdicts.1.verdict" "unknown"

write_state
expect_rc "stale head leaves state unchanged" 1 env FAKE_HEAD_SHA=def456 CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" bash "$SCRIPT" 123 "$ALL_FALSE" owner/repo
assert_state "stale method unchanged" "classification_method" "regex"
assert_state "stale critical unchanged" "critical" "1"
assert_state "stale high unchanged" "high" "1"

write_state
BAD_HASH="$(python3 - "$STATE_FILE" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
items = [
    {"index": 0, "comment_hash": "wrong", "verdict": "false_positive", "reasoning": "bad hash"},
    {"index": 1, "comment_hash": d["raw_comments"][1]["comment_hash"], "verdict": "false_positive", "reasoning": "ok"},
]
print(json.dumps(items, separators=(",", ":")))
PY
)"
expect_rc "hash mismatch leaves state unchanged" 1 run_script 123 "$BAD_HASH" owner/repo
assert_state "hash mismatch method unchanged" "classification_method" "regex"

write_state
MISSING="$(python3 - "$STATE_FILE" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
items = [
    {"index": 0, "comment_hash": d["raw_comments"][0]["comment_hash"], "verdict": "false_positive", "reasoning": "missing second"}
]
print(json.dumps(items, separators=(",", ":")))
PY
)"
expect_rc "missing severity verdict leaves state unchanged" 1 run_script 123 "$MISSING" owner/repo
assert_state "missing verdict method unchanged" "classification_method" "regex"

write_state
expect_rc "invalid JSON leaves state unchanged" 1 run_script 123 'not-json' owner/repo
assert_state "invalid JSON method unchanged" "classification_method" "regex"

write_state
expect_rc "same-head comment drift leaves state unchanged" 1 env FAKE_EXTRA_COMMENT=1 CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" bash "$SCRIPT" 123 "$ALL_FALSE" owner/repo
assert_state "comment drift method unchanged" "classification_method" "regex"

(
  cd "$TMP_REPO"
  FAKE_UNSAFE_APPROVAL=1 PATH="$TMP_BIN:$PATH" python3 "$ROOT/hooks/inject-claude-review-helper.py" owner/repo 123 >/dev/null 2>/dev/null
)
UNSAFE_FALSE="$(verdicts_json false_positive)"
expect_rc "mixed no-high false positive keeps gate closed" 2 env FAKE_UNSAFE_APPROVAL=1 CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" bash "$SCRIPT" 123 "$UNSAFE_FALSE" owner/repo
assert_state "mixed no-high method saved" "classification_method" "ai"
assert_state "mixed no-high high remains" "high" "1"

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "FAIL: $FAILED test(s) failed" >&2
  exit 1
fi

echo "ALL TESTS PASSED"
exit 0
