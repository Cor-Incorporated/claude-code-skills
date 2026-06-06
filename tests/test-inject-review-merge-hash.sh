#!/bin/bash
# test-inject-review-merge-hash.sh — inject-claude-review merge hash guard

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/inject-claude-review-on-checks.sh"
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
git -C "$TMP_REPO" remote add origin https://github.com/owner/repo.git

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/sh
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf 'abc123\n'
    exit 0
  fi
  printf '{"head":{"sha":"abc123"}}\n'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/comments" ]; then
  if [ "${FAKE_EXTRA_COMMENT:-0}" = "1" ]; then
    cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"No high findings.\n[HIGH] historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"},
  {"id":102,"commit_id":"abc123","path":"hooks/new.sh","line":20,"body":"[HIGH] new same-head review finding","user":{"login":"bot"},"updated_at":"2026-06-06T00:02:00Z"}
]
JSON
  else
    cat <<'JSON'
[
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"No high findings.\n[HIGH] historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"}
]
JSON
  fi
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
  local critical="${2:-0}"
  local high="${3:-0}"
  HASH="$hash" CRITICAL="$critical" HIGH="$high" PENDING_FILE="$PENDING_FILE" python3 - <<'PY'
import json
import os

critical = int(os.environ["CRITICAL"])
high = int(os.environ["HIGH"])
state = {
    "pr": "123",
    "repo": "owner/repo",
    "head_sha": "abc123",
    "comment_set_hash": os.environ["HASH"],
    "total": 2,
    "critical": critical,
    "high": high,
    "classification_method": "ai",
    "ai_classification": {"critical": critical, "high": high},
}
with open(os.environ["PENDING_FILE"], "w") as f:
    json.dump(state, f)
PY
}

clear_pending_head_sha() {
  PENDING_FILE="$PENDING_FILE" python3 - <<'PY'
import json
import os

path = os.environ["PENDING_FILE"]
d = json.load(open(path))
d["head_sha"] = ""
with open(path, "w") as f:
    json.dump(d, f)
PY
}

run_hook() {
  local command="$1"
  local payload
  payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$command")")
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$HOOK" <<<"$payload"
  )
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  local command="$3"
  shift 3
  local env_pair
  TOTAL=$((TOTAL + 1))
  local rc=0
  set +e
  for env_pair in "$@"; do
    export "$env_pair"
  done
  run_hook "$command" >/tmp/inject_merge_hash_test.out 2>/tmp/inject_merge_hash_test.err
  rc=$?
  for env_pair in "$@"; do
    unset "${env_pair%%=*}"
  done
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit $expected, got $rc)" >&2
    cat /tmp/inject_merge_hash_test.err >&2 || true
  fi
}

echo "=== inject review merge hash guard ==="

GOOD_HASH="$(calc_hash)"
write_pending "$GOOD_HASH"
expect_rc "T1: matching hash and zero severity allows merge command" 0 "gh pr merge 123 --merge"

write_pending "$GOOD_HASH"
expect_rc "T2: same-head comment drift blocks AI-cleared state" 2 "gh pr merge 123 --merge" FAKE_EXTRA_COMMENT=1

write_pending "$GOOD_HASH" 1 1
expect_rc "T3: command PR differs from pending state does not use other PR state" 0 "gh pr merge 456 --merge"

write_pending "$GOOD_HASH"
clear_pending_head_sha
expect_rc "T4: missing pending head SHA blocks standalone merge hook" 2 "gh pr merge 123 --merge"

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
rm -f /tmp/inject_merge_hash_test.out /tmp/inject_merge_hash_test.err
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
