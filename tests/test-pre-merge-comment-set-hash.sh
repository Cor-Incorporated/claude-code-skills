#!/bin/bash
# test-pre-merge-comment-set-hash.sh — PRE_MERGE comment_set_hash enforcement

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
TMP_HOME="$TMP_ROOT/home"
TMP_REPO="$TMP_ROOT/repo"
TMP_REMOTE="$TMP_ROOT/remote.git"
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
git -C "$TMP_REPO" branch develop
git -C "$TMP_REPO" branch -M feature
git clone -q --bare "$TMP_REPO" "$TMP_REMOTE"
git -C "$TMP_REPO" remote add origin "$TMP_REMOTE"
git -C "$TMP_REPO" push -q origin develop
export FAKE_BASE_SHA
FAKE_BASE_SHA="$(git -C "$TMP_REPO" rev-parse develop)"

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/sh
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123" ]; then
  if [ "${3:-}" = "--jq" ]; then
    case "${4:-}" in
      ".head.ref") printf 'feature\n' ;;
      ".head.sha") printf 'abc123\n' ;;
      ".base.ref") printf 'develop\n' ;;
      ".base.sha") printf '%s\n' "${FAKE_BASE_SHA:-abc123}" ;;
      *) printf 'abc123\n' ;;
    esac
    exit 0
  fi
  printf '{"head":{"sha":"abc123","ref":"feature"},"base":{"ref":"develop","sha":"%s"}}\n' "${FAKE_BASE_SHA:-abc123}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/999" ]; then
  if [ "${3:-}" = "--jq" ] && [ "${4:-}" = ".state" ]; then
    printf 'closed\n'
    exit 0
  fi
  printf '{"state":"closed"}\n'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/git/ref/heads/develop" ]; then
  if [ "${3:-}" = "--jq" ] && [ "${4:-}" = ".object.sha" ]; then
    printf '%s\n' "${FAKE_BASE_SHA:-abc123}"
    exit 0
  fi
  printf '{"object":{"sha":"%s"}}\n' "${FAKE_BASE_SHA:-abc123}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/files" ]; then
  file="${FAKE_CHANGED_FILE:-README.md}"
  if [ "${3:-}" = "--jq" ]; then
    printf '%s\n' "$file"
  else
    printf '[{"filename":"%s"}]\n' "$file"
  fi
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

write_other_closed_pending() {
  PENDING_FILE="$PENDING_FILE" python3 - <<'PY'
import json
import os

state = {
    "pr": "999",
    "repo": "owner/repo",
    "head_sha": "old",
    "total": 2,
    "critical": 1,
    "high": 1,
    "comment_set_hash": "stale",
}
with open(os.environ["PENDING_FILE"], "w") as f:
    json.dump(state, f)
PY
}

write_review_status() {
  local codex="${1:-false}"
  local code_sha="${2:-abc123}"
  local codex_sha="${3:-abc123}"
  CODEX="$codex" CODE_SHA="$code_sha" CODEX_SHA="$codex_sha" python3 - "$STATE_DIR/review-status.json" <<'PY'
import json
import os
import sys

codex = os.environ["CODEX"] == "true"
code_sha = os.environ["CODE_SHA"]
codex_sha = os.environ["CODEX_SHA"]
state = {
    "code_review": True,
    "codex_review": codex,
}
if code_sha:
    state["code_review_sha"] = code_sha
if codex_sha:
    state["codex_review_sha"] = codex_sha
with open(sys.argv[1], "w") as f:
    json.dump({"feature": state}, f)
PY
}

write_codex_only_status() {
  local codex_sha="${1:-abc123}"
  CODEX_SHA="$codex_sha" python3 - "$STATE_DIR/review-status.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w") as f:
    json.dump({"feature": {"codex_review": True, "codex_review_sha": os.environ["CODEX_SHA"]}}, f)
PY
}

write_gstack_review() {
  local payload="$1"
  local slug
  slug=$(git -C "$TMP_REPO" remote get-url origin | sed 's|^git@github.com:||;s|^https://github.com/||;s|^ssh://git@github.com/||;s|\.git$||' | tr '/' '-')
  mkdir -p "$TMP_HOME/.gstack/projects/$slug"
  printf '%s\n' "$payload" > "$TMP_HOME/.gstack/projects/$slug/feature-reviews.jsonl"
}

write_verified_lock() {
  local head_sha="${1:-abc123}"
  HEAD_SHA="$head_sha" python3 - "$STATE_DIR/pr-review-lock.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w") as f:
    json.dump({"123": {"verified": True, "head_sha": os.environ["HEAD_SHA"], "verified_head_sha": os.environ["HEAD_SHA"]}}, f)
PY
}

reset_state() {
  rm -f "$STATE_DIR/review-status.json" "$STATE_DIR/pr-review-lock.json"
  rm -rf "$TMP_HOME/.gstack"
  printf '{}\n' > "$STATE_DIR/review-status.json"
  printf '{}\n' > "$STATE_DIR/pr-review-lock.json"
}

run_pre_merge() {
  local payload='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --merge --repo owner/repo"}}'
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" \
      FAKE_CHANGED_FILE="${FAKE_CHANGED_FILE:-README.md}" \
      GATE_MODE=PRE_MERGE bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$payload"
  )
}

expect_rc() {
  local desc="$1"
  local expected="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  set +e
  run_pre_merge >/tmp/pre_merge_hash_test.out 2>/tmp/pre_merge_hash_test.err
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit $expected, got $rc)" >&2
    cat /tmp/pre_merge_hash_test.err >&2 || true
  fi
}

echo "=== pre-merge comment_set_hash enforcement ==="

GOOD_HASH="$(calc_hash)"

reset_state
write_pending "$GOOD_HASH"
expect_rc "T1: matching comment_set_hash allows Pass B" 0

reset_state
write_pending "stale"
write_review_status
expect_rc "T2: stale hash blocks even when Pass A is yes" 2

reset_state
write_pending "stale"
write_verified_lock
expect_rc "T3: stale hash blocks even when Pass C is yes" 2

reset_state
write_pending "$GOOD_HASH" no
expect_rc "T4: missing comment_set_hash blocks" 2

reset_state
write_pending "stale"
write_review_status true
expect_rc "T5: stale hash blocks even with Tier 1 LGTM" 2

reset_state
write_other_closed_pending
write_review_status
expect_rc "T6: closed other-PR pending state is purged and ignored" 0
if [[ ! -f "$PENDING_FILE" ]]; then
  PASSED=$((PASSED + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: T6b: closed pending file removed"
else
  FAILED=$((FAILED + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: T6b: closed pending file still present" >&2
fi

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_review_status true oldsha oldsha
expect_rc "T7: FULL tier stale review SHAs block boolean-only approval" 2

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_review_status true abc123 abc123
expect_rc "T8: FULL tier matching review SHAs allow Tier 1 LGTM" 0

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_codex_only_status abc123
write_gstack_review '{"status":"approved"}'
expect_rc "T9: gstack review without commit does not satisfy same-head evidence" 2

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_codex_only_status abc123
write_gstack_review '{"status":"approved","commit":"abc123"}'
expect_rc "T10: gstack review with matching commit hydrates code-review evidence" 0

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_codex_only_status abc123
write_gstack_review '{"status":"approved","commit":"abc123"}'
expect_rc "T11: gstack review with short matching commit hydrates code-review evidence" 0

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_codex_only_status abc123
write_verified_lock oldsha
expect_rc "T12: stale verified lock does not satisfy Pass C" 2

reset_state
FAKE_CHANGED_FILE="src/app.ts"
write_codex_only_status abc123
write_verified_lock abc123
expect_rc "T13: matching verified lock satisfies Pass C" 0
FAKE_CHANGED_FILE="README.md"

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
rm -f /tmp/pre_merge_hash_test.out /tmp/pre_merge_hash_test.err
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
