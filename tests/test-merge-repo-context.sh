#!/bin/bash
# Regression harness for merge hooks that receive an explicit --repo target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

SRC_REPO="$TMP_ROOT/source"
TARGET_REPO="$TMP_ROOT/target"
OTHER_REPO="$TMP_ROOT/other"
TMP_HOME="$TMP_ROOT/home"
TMP_BIN="$TMP_ROOT/bin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$TMP_BIN" "$TMP_HOME/.claude/state"

for repo in "$SRC_REPO" "$TARGET_REPO" "$OTHER_REPO"; do
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf '# test\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  mkdir -p "$repo/.claude/state"
done
git -C "$SRC_REPO" remote add origin git@github.com:owner/source.git
git -C "$TARGET_REPO" remote add origin git@github.com:owner/target.git
git -C "$OTHER_REPO" remote add origin git@github.com:owner/other.git

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"

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
  repos/owner/target/pulls/123)
    case "$jq_expr" in
      ".head.sha"|".head.sha // \"\"") printf 'targetsha\n' ;;
      ".head.ref"|".head.ref // \"\"") printf 'feat/target\n' ;;
      ".base.ref // \"\"") printf 'develop\n' ;;
      *) printf '{"head":{"sha":"targetsha","ref":"feat/target"},"base":{"ref":"develop"}}\n' ;;
    esac
    ;;
  repos/owner/target/commits/targetsha/check-runs)
    case "$jq_expr" in
      *'status != "completed"'*) printf '0\n' ;;
      *'conclusion == "failure"'*) printf '0\n' ;;
      *'test("claude-review"'*) printf 'success\n' ;;
      *) printf '{"check_runs":[{"name":"claude-review","status":"completed","conclusion":"success"}]}\n' ;;
    esac
    ;;
  repos/owner/target/issues/123/comments)
    case "$jq_expr" in
      length) printf '1\n' ;;
      *'.[].body'*) printf 'review LGTM\n' ;;
      *)
        cat <<'JSON'
[{"body":"review LGTM","user":{"login":"claude[bot]","type":"Bot"},"updated_at":"2026-07-03T00:00:00Z"}]
JSON
        ;;
    esac
    ;;
  repos/owner/target/pulls/123/comments)
    printf '[]\n'
    ;;
  repos/owner/target/pulls/123/files)
    case "$jq_expr" in
      *filename*) printf 'src/index.ts\n' ;;
      *) printf '[{"filename":"src/index.ts"}]\n' ;;
    esac
    ;;
  repos/owner/source/*)
    echo "unexpected source repo API: $path" >&2
    exit 9
    ;;
  *)
    printf '{}\n'
    ;;
esac
FAKEGH
chmod +x "$TMP_BIN/gh"

PASS=0
FAIL=0

payload() {
  jq -n --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

run_hook() {
  local hook="$1"
  local command="$2"
  (
    cd "$SRC_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$SRC_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload "$command")"
  )
}

expect_block() {
  local desc="$1" hook="$2" command="$3"
  local rc
  : > "$GH_LOG"
  set +e
  run_hook "$hook" "$command" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected block exit 2, got $rc)" >&2
    echo "--- stderr ---" >&2
    cat "$TMP_ROOT/err" >&2 || true
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
  fi

  if grep -q 'repos/owner/target/pulls/123' "$GH_LOG"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc inspected --repo target"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc did not inspect --repo target" >&2
    cat "$GH_LOG" >&2 || true
  fi
}

expect_allow() {
  local desc="$1" hook="$2" command="$3"
  : > "$GH_LOG"
  if run_hook "$hook" "$command" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    local rc=$?
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected allow exit 0, got $rc)" >&2
    echo "--- stderr ---" >&2
    cat "$TMP_ROOT/err" >&2 || true
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
  fi

  if grep -q 'repos/owner/target/pulls/123' "$GH_LOG"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc inspected --repo target"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc did not inspect --repo target" >&2
    cat "$GH_LOG" >&2 || true
  fi
}

echo "=== merge hook --repo context ==="

printf '{"123":{"review_read":true,"repo":"owner/source","head_sha":"targetsha"}}\n' \
  > "$SRC_REPO/.claude/state/pr-review-read.json"
printf '{}\n' > "$TARGET_REPO/.claude/state/pr-review-read.json"
expect_block \
  "pr-merge gate does not accept cwd review_read for --repo target" \
  "pr-merge-claude-review-gate.sh" \
  "gh pr merge 123 --merge --repo owner/target"

printf '{"123":{"verified":true,"repo":"owner/source","head_sha":"targetsha","verified_head_sha":"targetsha"}}\n' \
  > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":false,"repo":"owner/target","head_sha":"targetsha"}}\n' \
  > "$TARGET_REPO/.claude/state/pr-review-lock.json"
expect_block \
  "block-merge hook does not accept cwd lock state for --repo target" \
  "block-merge-without-review.sh" \
  "gh pr merge 123 --merge --repo owner/target"

printf '{"123":{"verified":false,"repo":"owner/source","head_sha":"targetsha"}}\n' \
  > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":true,"repo":"owner/target","head_sha":"targetsha","verified_head_sha":"targetsha"}}\n' \
  > "$TARGET_REPO/.claude/state/pr-review-lock.json"
expect_allow \
  "block-merge hook accepts target repo verified lock state" \
  "block-merge-without-review.sh" \
  "gh pr merge 123 --merge --repo owner/target"

printf '{}\n' > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":false,"repo":"owner/target","head_sha":"oldsha"}}\n' \
  > "$TARGET_REPO/.claude/state/pr-review-lock.json"
expect_allow \
  "block-merge hook ignores stale target repo pending lock state" \
  "block-merge-without-review.sh" \
  "gh pr merge 123 --merge --repo owner/target"

printf '{}\n' > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{}\n' > "$TARGET_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":false,"repo":"owner/target","head_sha":"targetsha"}}\n' \
  > "$OTHER_REPO/.claude/state/pr-review-lock.json"
expect_allow \
  "block-merge hook ignores inert env assignment command text for context" \
  "block-merge-without-review.sh" \
  "env NOTE='cd $OTHER_REPO && gh pr merge 123 --merge --repo owner/target' gh pr merge 123 --merge --repo owner/target"

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
