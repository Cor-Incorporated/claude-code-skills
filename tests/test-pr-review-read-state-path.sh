#!/bin/bash
# Regression coverage for pr-review-read.json path mismatch (#252).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TMP_HOME="$TMP_ROOT/home"
TMP_PARENT="$TMP_ROOT/parent"
TMP_REPO="$TMP_PARENT/repo"
TMP_BIN="$TMP_ROOT/bin"
mkdir -p "$TMP_HOME/.claude/state" "$TMP_PARENT/.claude/state" "$TMP_BIN"

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# test\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" remote add origin git@github.com:owner/repo.git
mkdir -p "$TMP_REPO/.claude/state"

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/bash
if [[ "${1:-}" != "api" ]]; then
  printf '{}\n'
  exit 0
fi

path="${2:-}"
jq_expr=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--jq" ]]; then
    jq_expr="$arg"
    break
  fi
  prev="$arg"
done

case "$path" in
  repos/owner/repo/pulls/123)
    case "$jq_expr" in
      ".head.sha"|".head.sha // \"\"") printf 'abc123\n' ;;
      ".head.ref"|".head.ref // \"\"") printf 'fix/test\n' ;;
      *) printf '{"head":{"sha":"abc123","ref":"fix/test"},"base":{"ref":"develop"}}\n' ;;
    esac
    ;;
  repos/owner/repo/commits/abc123/check-runs)
    case "$jq_expr" in
      *'status != "completed"'*) printf '0\n' ;;
      *'conclusion == "failure"'*) printf '0\n' ;;
      *'test("claude-review"'*) printf '%s\n' "${FAKE_CLAUDE_STATUS:-success}" ;;
      *) printf '{"check_runs":[{"name":"claude-review","status":"completed","conclusion":"success"}]}\n' ;;
    esac
    ;;
  repos/owner/repo/issues/123/comments)
    if [[ "${FAKE_NO_COMMENTS:-0}" == "1" ]]; then
      case "$jq_expr" in
        length) printf '0\n' ;;
        *'.[].body'*) printf '\n' ;;
        *) printf '[]\n' ;;
      esac
    else
      case "$jq_expr" in
        length) printf '1\n' ;;
        *'.[].body'*)
          if [[ "${FAKE_COMMENT_CRITICAL:-0}" == "1" ]]; then
            printf '[CRITICAL] blocker\n'
          else
            printf 'review LGTM\n'
          fi
          ;;
        *)
          cat <<'JSON'
[{"body":"review LGTM","user":{"login":"claude[bot]","type":"Bot"},"updated_at":"2026-06-30T00:00:00Z"}]
JSON
          ;;
      esac
    fi
    ;;
  repos/owner/repo/pulls/123/reviews)
    printf '[]\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
FAKEGH
chmod +x "$TMP_BIN/gh"

PASS=0
FAIL=0

reset_state() {
  rm -rf "$TMP_HOME/.claude/state" "$TMP_PARENT/.claude/state" "$TMP_REPO/.claude/state"
  mkdir -p "$TMP_HOME/.claude/state" "$TMP_PARENT/.claude/state" "$TMP_REPO/.claude/state"
  printf '{}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
  printf '{}\n' > "$TMP_PARENT/.claude/state/pr-review-read.json"
  printf '{}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
}

payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

run_merge_gate() {
  local command="${1:-gh pr merge 123 --merge --repo owner/repo}"
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PARENT" PATH="$TMP_BIN:$PATH" \
      bash "$ROOT/hooks/pr-merge-claude-review-gate.sh" <<<"$(payload "$command")"
  )
}

run_merge_gate_no_comments() {
  FAKE_NO_COMMENTS=1 run_merge_gate
}

run_merge_gate_critical_status() {
  FAKE_CLAUDE_STATUS=failure run_merge_gate
}

run_verify_script() {
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PARENT" PATH="$TMP_BIN:$PATH" \
      bash "$ROOT/scripts/verify-pr-review.sh" 123 owner/repo
  )
}

json_field_true() {
  local file="$1" field="$2"
  python3 - "$file" "$field" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sys.exit(0 if data.get("123", {}).get(sys.argv[2]) is True else 1)
PY
}

expect_rc() {
  local desc="$1" expected="$2"
  shift 2
  local rc=0
  set +e
  "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected $expected, got $rc)" >&2
    cat "$TMP_ROOT/err" >&2 || true
  fi
}

echo "=== pr-review-read state path regression ==="

reset_state
printf '{"123":{"review_read":true}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate accepts global review_read when CLAUDE_PROJECT_DIR is parent" 0 run_merge_gate

reset_state
printf '{"123":{"review_read":true}}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
expect_rc "merge gate accepts git-root review_read when CLAUDE_PROJECT_DIR is parent" 0 run_merge_gate

reset_state
expect_rc "merge gate still blocks when review_read is absent everywhere" 2 run_merge_gate
if grep -q "レビューを未読" "$TMP_ROOT/err"; then
  PASS=$((PASS + 1))
  echo "  PASS: unread block reason is preserved"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: unread block reason missing" >&2
  cat "$TMP_ROOT/err" >&2 || true
fi

reset_state
printf '{"123":{"fallback_review_done":true,"review_read":true}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate OR-reads fallback_review_done from global state" 0 run_merge_gate_no_comments

reset_state
printf '{"123":{"review_read":true,"has_critical":true}}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
printf '{"123":{"critical_acknowledged":true}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate OR-reads critical fallback and acknowledgement" 0 run_merge_gate_critical_status

reset_state
expect_rc "verify-pr-review writes review_read successfully" 0 run_verify_script
for state_file in \
  "$TMP_PARENT/.claude/state/pr-review-read.json" \
  "$TMP_REPO/.claude/state/pr-review-read.json" \
  "$TMP_HOME/.claude/state/pr-review-read.json"; do
  if json_field_true "$state_file" review_read; then
    PASS=$((PASS + 1))
    echo "  PASS: verify-pr-review wrote ${state_file#$TMP_ROOT/}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: verify-pr-review did not write ${state_file#$TMP_ROOT/}" >&2
    cat "$state_file" >&2 || true
  fi
done

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
