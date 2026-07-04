#!/bin/bash
# Regression coverage: subagent POST_PUSH must not bypass review invalidation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TMP_HOME="$TMP_ROOT/home"
TMP_REPO="$TMP_ROOT/repo"
OTHER_REPO="$TMP_ROOT/other"
TMP_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_REPO/.claude/state"
OTHER_STATE_DIR="$OTHER_REPO/.claude/state"
GLOBAL_STATE_DIR="$TMP_HOME/.claude/state"
mkdir -p "$TMP_HOME" "$TMP_BIN" "$STATE_DIR" "$OTHER_STATE_DIR" "$GLOBAL_STATE_DIR"

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# test\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" branch develop
git -C "$TMP_REPO" branch -M feature
git -C "$TMP_REPO" remote add origin git@github.com:owner/repo.git

git init -q "$OTHER_REPO"
git -C "$OTHER_REPO" config user.email test@example.com
git -C "$OTHER_REPO" config user.name Test
printf '# other\n' > "$OTHER_REPO/README.md"
git -C "$OTHER_REPO" add README.md
git -C "$OTHER_REPO" commit -q -m init
git -C "$OTHER_REPO" branch -M other
git -C "$OTHER_REPO" remote add origin git@github.com:owner/other.git

REVIEWED_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
mkdir -p "$TMP_REPO/src"
printf 'export const value = 1\n' > "$TMP_REPO/src/app.ts"
git -C "$TMP_REPO" add src/app.ts
git -C "$TMP_REPO" commit -q -m 'add source'
HEAD_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/bash
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  printf '123\n'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/123" ]]; then
  if [[ "${3:-}" == "--jq" ]]; then
    case "${4:-}" in
      ".head.ref"|".head.ref // \"\"") printf 'feature\n' ;;
      ".head.sha"|".head.sha // \"\"") printf '%s\n' "${FAKE_HEAD_SHA:-}" ;;
      *) printf '%s\n' "${FAKE_HEAD_SHA:-}" ;;
    esac
    exit 0
  fi
  printf '{"head":{"ref":"feature","sha":"%s"}}\n' "${FAKE_HEAD_SHA:-}"
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/123/files" ]]; then
  printf 'src/app.ts\n'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/123/comments" ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/123/comments" ]]; then
  if [[ "${3:-}" == "--jq" && "${4:-}" == *'.[].body'* ]]; then
    printf 'LGTM\n'
  else
    printf '[{"body":"LGTM","user":{"login":"claude[bot]","type":"Bot"}}]\n'
  fi
  exit 0
fi
case "${2:-}" in
  repos/owner/repo/commits/*/check-runs)
    if [[ "${3:-}" == "--jq" ]]; then
      case "${4:-}" in
        *'status != "completed"'*) printf '0\n' ;;
        *'conclusion == "failure"'*) printf '0\n' ;;
        *'test("claude-review"'*) printf 'success\n' ;;
        *) printf '0\n' ;;
      esac
    else
      printf '{"check_runs":[{"name":"claude-review","status":"completed","conclusion":"success"}]}\n'
    fi
    exit 0
    ;;
esac
exit 1
FAKEGH
chmod +x "$TMP_BIN/gh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

write_review_status() {
  local file="$1"
  REVIEWED_SHA="$REVIEWED_SHA" python3 - "$file" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w") as f:
    json.dump({
        "feature": {
            "code_review": True,
            "code_review_sha": os.environ["REVIEWED_SHA"],
        }
    }, f)
PY
}

has_branch_review() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
sys.exit(0 if "feature" in data else 1)
PY
}

lock_is_pending() {
  HEAD_SHA="$HEAD_SHA" python3 - "$1" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
entry = data.get("123", {})
sys.exit(0 if (
    entry.get("status") == "review_pending"
    and entry.get("branch") == "feature"
    and entry.get("repo") == "owner/repo"
    and entry.get("head_sha") == os.environ["HEAD_SHA"]
) else 1)
PY
}

run_post_push() {
  local command="$1"
  local run_cwd="${2:-$TMP_REPO}"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")
  (
    cd "$run_cwd"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$run_cwd" PATH="$TMP_BIN:$PATH" FAKE_HEAD_SHA="$HEAD_SHA" \
      CLAUDE_AGENT_DEPTH=1 GATE_MODE=POST_PUSH \
      bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$payload"
  )
}

run_block_merge() {
  local payload
  payload=$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --merge --repo owner/repo"}}))')
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" FAKE_HEAD_SHA="$HEAD_SHA" \
      bash "$ROOT/hooks/block-merge-without-review.sh" <<<"$payload"
  )
}

echo "=== post-push subagent invalidation ==="

write_review_status "$STATE_DIR/review-status.json"
write_review_status "$GLOBAL_STATE_DIR/review-status.json"
if run_post_push "git push origin feature" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  pass "T1: subagent git push is allowed after post-push processing"
else
  fail "T1: subagent git push hook failed"
  cat "$TMP_ROOT/err" >&2 || true
fi

if ! has_branch_review "$STATE_DIR/review-status.json" && ! has_branch_review "$GLOBAL_STATE_DIR/review-status.json"; then
  pass "T2: source push invalidates project and global review evidence"
else
  fail "T2: stale review evidence remained"
fi

if lock_is_pending "$STATE_DIR/pr-review-lock.json" && lock_is_pending "$GLOBAL_STATE_DIR/pr-review-lock.json"; then
  pass "T3: subagent push writes project and global pessimistic locks"
else
  fail "T3: pessimistic lock missing after subagent push"
fi

set +e
run_block_merge >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
set -e
if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_ROOT/err"; then
  pass "T3b: post-push lock is consumed by merge review gate"
else
  fail "T3b: post-push lock did not block merge"
  cat "$TMP_ROOT/err" >&2 || true
fi

rm -f "$STATE_DIR/pr-review-lock.json" "$OTHER_STATE_DIR/pr-review-lock.json" "$GLOBAL_STATE_DIR/pr-review-lock.json"
write_review_status "$STATE_DIR/review-status.json"
write_review_status "$GLOBAL_STATE_DIR/review-status.json"
if run_post_push "cd '$TMP_REPO' && git push origin feature" "$OTHER_REPO" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  pass "T3c: cd-prefixed git push is allowed from foreign hook cwd"
else
  fail "T3c: cd-prefixed git push failed from foreign hook cwd"
  cat "$TMP_ROOT/err" >&2 || true
fi

if lock_is_pending "$STATE_DIR/pr-review-lock.json" && lock_is_pending "$GLOBAL_STATE_DIR/pr-review-lock.json"; then
  pass "T3d: cd-prefixed git push writes target repo/global lock state"
else
  fail "T3d: cd-prefixed git push did not write target repo/global lock state"
  cat "$TMP_ROOT/err" >&2 || true
fi

if [[ ! -f "$OTHER_STATE_DIR/pr-review-lock.json" ]] || ! python3 - "$OTHER_STATE_DIR/pr-review-lock.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {}
sys.exit(0 if "123" in data else 1)
PY
then
  pass "T3e: cd-prefixed git push does not write foreign cwd repo lock"
else
  fail "T3e: cd-prefixed git push wrote lock in foreign cwd repo"
fi

rm -f "$STATE_DIR/pr-review-lock.json" "$GLOBAL_STATE_DIR/pr-review-lock.json"
write_review_status "$STATE_DIR/review-status.json"
write_review_status "$GLOBAL_STATE_DIR/review-status.json"
if run_post_push "git status" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  pass "T4: subagent non-push POST_PUSH remains exempt"
else
  fail "T4: subagent non-push POST_PUSH failed"
  cat "$TMP_ROOT/err" >&2 || true
fi

if has_branch_review "$STATE_DIR/review-status.json" && has_branch_review "$GLOBAL_STATE_DIR/review-status.json"; then
  pass "T5: subagent non-push does not invalidate review evidence"
else
  fail "T5: subagent non-push changed review evidence"
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
