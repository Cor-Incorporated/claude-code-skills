#!/bin/bash
# test-review-comment-set-hash.sh — helper/updater hash parity tests

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/review-comment-set-hash.sh"
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
  if [ "${FAKE_EXTRA_COMMENT:-0}" = "1" ]; then
    cat <<'JSON'
[
  {"id":99,"commit_id":"oldsha","path":"old.sh","line":1,"body":"[HIGH] old-head finding","user":{"login":"bot"},"updated_at":"2026-06-05T23:59:00Z"},
  {"id":101,"commit_id":"abc123","path":"hooks/example.sh","line":10,"body":"No high findings.\n[HIGH] historical heading only","user":{"login":"bot"},"updated_at":"2026-06-06T00:00:00Z"},
  {"id":102,"commit_id":"abc123","path":"hooks/new.sh","line":20,"body":"[HIGH] new same-head review finding","user":{"login":"bot"},"updated_at":"2026-06-06T00:02:00Z"}
]
JSON
  else
    cat <<'JSON'
[
  {"id":99,"commit_id":"oldsha","path":"old.sh","line":1,"body":"[HIGH] old-head finding","user":{"login":"bot"},"updated_at":"2026-06-05T23:59:00Z"},
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

pass() {
  PASSED=$((PASSED + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: $1"
}

fail() {
  FAILED=$((FAILED + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: $1" >&2
}

state_hash() {
  python3 - "$STATE_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1])).get("comment_set_hash", ""))
PY
}

calc_hash() {
  PATH="$TMP_BIN:$PATH" bash "$SCRIPT" 123 owner/repo abc123
}

write_state() {
  (
    cd "$TMP_REPO"
    PATH="$TMP_BIN:$PATH" python3 "$ROOT/hooks/inject-claude-review-helper.py" owner/repo 123 >/dev/null 2>/dev/null
  )
}

echo "=== review-comment-set-hash parity ==="

write_state
HELPER_HASH="$(state_hash)"
SCRIPT_HASH="$(calc_hash)"
[[ "$HELPER_HASH" == "$SCRIPT_HASH" ]] && pass "T1: hash matches inject helper comment_set_hash" || fail "T1: helper/script hash mismatch"

BASE_HASH="$SCRIPT_HASH"
OLD_HEAD_HASH="$(calc_hash)"
[[ "$BASE_HASH" == "$OLD_HEAD_HASH" ]] && pass "T2: old-head inline comments do not affect hash" || fail "T2: old-head comment changed hash"

EXTRA_HASH="$(FAKE_EXTRA_COMMENT=1 calc_hash)"
[[ "$BASE_HASH" != "$EXTRA_HASH" ]] && pass "T3: same-head new inline comment changes hash" || fail "T3: same-head extra comment did not change hash"

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
