#!/bin/bash
# Regression coverage: subagent POST_PUSH must not bypass review invalidation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TMP_HOME="$TMP_ROOT/home"
TMP_REPO="$TMP_ROOT/repo"
TMP_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_REPO/.claude/state"
GLOBAL_STATE_DIR="$TMP_HOME/.claude/state"
mkdir -p "$TMP_HOME" "$TMP_BIN" "$STATE_DIR" "$GLOBAL_STATE_DIR"

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# test\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" branch develop
git -C "$TMP_REPO" branch -M feature
git -C "$TMP_REPO" remote add origin git@github.com:owner/repo.git

REVIEWED_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
mkdir -p "$TMP_REPO/src"
printf 'export const value = 1\n' > "$TMP_REPO/src/app.ts"
git -C "$TMP_REPO" add src/app.ts
git -C "$TMP_REPO" commit -q -m 'add source'

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/bash
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  printf '123\n'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/123/files" ]]; then
  printf 'src/app.ts\n'
  exit 0
fi
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
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
entry = data.get("123", {})
sys.exit(0 if entry.get("status") == "review_pending" and entry.get("branch") == "feature" else 1)
PY
}

run_post_push() {
  local command="$1"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" \
      CLAUDE_AGENT_DEPTH=1 GATE_MODE=POST_PUSH \
      bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$payload"
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
