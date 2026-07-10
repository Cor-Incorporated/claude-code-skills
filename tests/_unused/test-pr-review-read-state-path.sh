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
git -C "$TMP_REPO" branch -M develop
TMP_REMOTE="$TMP_ROOT/remote.git"
git clone -q --bare "$TMP_REPO" "$TMP_REMOTE"
git -C "$TMP_REPO" remote add origin "$TMP_REMOTE"
git -C "$TMP_REPO" push -q origin develop
TEST_BASE_SHA="$(git -C "$TMP_REPO" rev-parse develop)"
export TEST_BASE_SHA
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
head_sha="${FAKE_HEAD_SHA:-abc123}"
if [[ "${FAKE_NO_HEAD:-0}" == "1" ]]; then
  head_sha=""
fi

case "$path" in
  repos/owner/repo/pulls/123)
    case "$jq_expr" in
      ".head.sha"|".head.sha // \"\"") printf '%s\n' "$head_sha" ;;
      ".head.ref"|".head.ref // \"\"") printf 'fix/test\n' ;;
      ".base.ref"|".base.ref // \"\"") printf 'develop\n' ;;
      ".base.sha"|".base.sha // \"\"") printf '%s\n' "${TEST_BASE_SHA:-developsha}" ;;
      *) printf '{"head":{"sha":"%s","ref":"fix/test"},"base":{"ref":"develop","sha":"%s"}}\n' "$head_sha" "${TEST_BASE_SHA:-developsha}" ;;
    esac
    ;;
  repos/owner/repo/git/ref/heads/develop)
    if [[ "$jq_expr" == ".object.sha" ]]; then
      printf '%s\n' "${TEST_BASE_SHA:-developsha}"
    else
      printf '{"object":{"sha":"%s"}}\n' "${TEST_BASE_SHA:-developsha}"
    fi
    ;;
  repos/owner/repo/commits/*/check-runs)
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
  repos/owner/repo/pulls/123/files)
    # Empty array: classify_review_tier falls back to LIGHT (no source files).
    case "$jq_expr" in
      *filename*) printf '\n' ;;
      *) printf '[]\n' ;;
    esac
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
  # Phase 3: consolidated pre-merge.sh requires 3-pass judgment after Gate 0-4.
  # Seed review-status.json with code_review=true so Pass A succeeds for the
  # happy-path cases. Tests that expect a block override this or omit it.
  for state_dir in "$TMP_HOME/.claude/state" "$TMP_PARENT/.claude/state" "$TMP_REPO/.claude/state"; do
    printf '{"fix/test":{"code_review":true,"code_review_sha":"abc123"}}\n' > "$state_dir/review-status.json"
  done
}

payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

run_merge_gate() {
  local command="${1:-gh pr merge 123 --merge --repo owner/repo}"
  (
    cd "$TMP_REPO"
	    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_PARENT" PATH="$TMP_BIN:$PATH" \
	      FAKE_NO_HEAD="${FAKE_NO_HEAD:-0}" FAKE_HEAD_SHA="${FAKE_HEAD_SHA:-abc123}" \
	      FAKE_NO_COMMENTS="${FAKE_NO_COMMENTS:-0}" FAKE_CLAUDE_STATUS="${FAKE_CLAUDE_STATUS:-success}" \
	      FAKE_COMMENT_CRITICAL="${FAKE_COMMENT_CRITICAL:-0}" \
	      GATE_MODE=PRE_MERGE bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$(payload "$command")"
  )
}

run_merge_gate_no_comments() {
  FAKE_NO_COMMENTS=1 run_merge_gate
}

run_merge_gate_critical_status() {
  FAKE_CLAUDE_STATUS=failure run_merge_gate
}

run_merge_gate_no_head() {
  FAKE_NO_HEAD=1 run_merge_gate
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

json_field_equals() {
  local file="$1" field="$2" expected="$3"
  python3 - "$file" "$field" "$expected" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sys.exit(0 if str(data.get("123", {}).get(sys.argv[2], "")) == sys.argv[3] else 1)
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
printf '{"123":{"review_read":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate accepts global review_read when CLAUDE_PROJECT_DIR is parent" 0 run_merge_gate

reset_state
printf '{"123":{"review_read":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
expect_rc "merge gate accepts git-root review_read when CLAUDE_PROJECT_DIR is parent" 0 run_merge_gate

reset_state
printf '{"123":{"review_read":true,"repo":"owner/repo","head_sha":"old123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate blocks stale review_read after push" 2 run_merge_gate
if grep -q "head_sha と一致しません" "$TMP_ROOT/err"; then
  PASS=$((PASS + 1))
  echo "  PASS: stale head block reason is reported"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: stale head block reason missing" >&2
  cat "$TMP_ROOT/err" >&2 || true
fi

reset_state
printf '{"123":{"review_read":true,"repo":"other/repo","head_sha":"abc123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate blocks foreign repo review_read with same PR number" 2 run_merge_gate
if grep -q "別リポジトリ" "$TMP_ROOT/err"; then
  PASS=$((PASS + 1))
  echo "  PASS: foreign repo block reason is reported"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: foreign repo block reason missing" >&2
  cat "$TMP_ROOT/err" >&2 || true
fi

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
printf '{"123":{"fallback_review_done":true,"review_read":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate OR-reads fallback_review_done from global state" 0 run_merge_gate_no_comments

reset_state
printf '{"123":{"review_read":true,"has_critical":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_REPO/.claude/state/pr-review-read.json"
printf '{"123":{"critical_acknowledged":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate OR-reads critical fallback and acknowledgement" 0 run_merge_gate_critical_status

reset_state
printf '{"123":{"review_read":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TMP_HOME/.claude/state/pr-review-read.json"
expect_rc "merge gate fails closed when PR head cannot be resolved" 2 run_merge_gate_no_head
if grep -q "HEAD SHA を取得できません" "$TMP_ROOT/err"; then
  PASS=$((PASS + 1))
  echo "  PASS: head resolution failure is reported"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: head resolution block reason missing" >&2
  cat "$TMP_ROOT/err" >&2 || true
fi

reset_state
expect_rc "verify-pr-review writes review_read successfully" 0 run_verify_script
for state_file in \
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
  if json_field_equals "$state_file" head_sha abc123; then
    PASS=$((PASS + 1))
    echo "  PASS: verify-pr-review wrote head_sha to ${state_file#$TMP_ROOT/}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: verify-pr-review did not write head_sha to ${state_file#$TMP_ROOT/}" >&2
    cat "$state_file" >&2 || true
  fi
done

if json_field_true "$TMP_PARENT/.claude/state/pr-review-read.json" review_read; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: verify-pr-review wrote broad parent state unexpectedly" >&2
  cat "$TMP_PARENT/.claude/state/pr-review-read.json" >&2 || true
else
  PASS=$((PASS + 1))
  echo "  PASS: verify-pr-review did not write broad parent state"
fi

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
