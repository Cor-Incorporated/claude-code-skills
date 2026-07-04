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
  # develop branch required so pre-merge.sh ensure_pr_base_fresh can resolve
  # the GitHub base ref against a local fetchable remote (Phase 3 consolidation
  # routes every gh pr merge through gate-modes/pre-merge.sh).
  git -C "$repo" branch develop
  mkdir -p "$repo/.claude/state"
done
git -C "$SRC_REPO" remote add origin git@github.com:owner/source.git
git -C "$TARGET_REPO" remote add origin git@github.com:owner/target.git
git -C "$OTHER_REPO" remote add origin git@github.com:owner/other.git

# Map each github.com origin URL to a local bare remote so the consolidated
# pre-merge.sh ensure_pr_base_fresh can `git fetch origin develop` in the
# sandbox. remote_slug() still sees `owner/<name>` because each repo's origin
# URL keeps its github.com form (insteadOf rewrites only what git fetch/push
# uses); local_repo_root_for_slug() therefore still resolves target/other
# checkouts during cross-repo merge tests.
SRC_REMOTE="$TMP_ROOT/source.git"
TGT_REMOTE="$TMP_ROOT/target.git"
git clone -q --bare "$SRC_REPO" "$SRC_REMOTE"
git clone -q --bare "$TARGET_REPO" "$TGT_REMOTE"
git -C "$SRC_REPO" config "url.${SRC_REMOTE}.insteadOf" "git@github.com:owner/source.git"
git -C "$TARGET_REPO" config "url.${TGT_REMOTE}.insteadOf" "git@github.com:owner/target.git"
git -C "$SRC_REPO" push -q origin develop
git -C "$TARGET_REPO" push -q origin develop
SRC_DEVELOP_SHA="$(git -C "$SRC_REPO" rev-parse develop)"
export SRC_DEVELOP_SHA

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
      ".base.ref"|".base.ref // \"\"") printf 'develop\n' ;;
      ".base.sha"|".base.sha // \"\"") printf '%s\n' "$SRC_DEVELOP_SHA" ;;
      *) printf '{"head":{"sha":"targetsha","ref":"feat/target"},"base":{"ref":"develop","sha":"%s"}}\n' "$SRC_DEVELOP_SHA" ;;
    esac
    ;;
  repos/owner/target/git/ref/heads/develop)
    if [[ "$jq_expr" == ".object.sha" ]]; then
      printf '%s\n' "$SRC_DEVELOP_SHA"
    else
      printf '{"object":{"sha":"%s"}}\n' "$SRC_DEVELOP_SHA"
    fi
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
      GATE_MODE=PRE_MERGE bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$(payload "$command")"
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

# seed_target_review_ok — write review_read + review-status that satisfy the
# consolidated pre-merge.sh Gate 3 (review_read current) and the FULL-tier
# 3-pass judgment for the TARGET repo. The consolidated dispatcher runs every
# gate for `gh pr merge`, so allow cases must keep the non-lock gates green
# while still exercising lock-state handling.
#
# review-status.json seeds code_review (Pass A) plus the Issue #203 Codex
# severity override (codex_review_ran + codex_critical/high = 0). codex_review
# is intentionally NOT set so PRIMARY_LGTM stays false and the pessimistic
# lock gate at pre-merge.sh line 224 still fires — otherwise the lock state
# under test would be bypassed entirely.
seed_target_review_ok() {
  printf '{"123":{"review_read":true,"repo":"owner/target","head_sha":"targetsha"}}\n' \
    > "$TARGET_REPO/.claude/state/pr-review-read.json"
  printf '{}\n' > "$SRC_REPO/.claude/state/pr-review-read.json"
  # review-status.json is read from $REVIEW_STATE (cwd project state) and
  # $HOME/.claude/state (review_state_files helper), not from the target
  # repo. Write to both so the consolidated pre-merge.sh 3-pass judgment
  # (Pass A code_review + Issue #203 Codex severity override) is satisfied
  # without triggering PRIMARY_LGTM (codex_review stays unset).
  local _review_status
  _review_status='{"feat/target":{"code_review":true,"code_review_sha":"targetsha","codex_review_ran":true,"codex_review_sha":"targetsha","codex_critical":0,"codex_high":0}}'
  printf '%s\n' "$_review_status" > "$SRC_REPO/.claude/state/review-status.json"
  printf '%s\n' "$_review_status" > "$TMP_HOME/.claude/state/review-status.json"
  rm -f "$TARGET_REPO/.claude/state/pending-review-comments.json" \
        "$SRC_REPO/.claude/state/pending-review-comments.json"
}

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

seed_target_review_ok
printf '{"123":{"verified":false,"repo":"owner/source","head_sha":"targetsha"}}\n' \
  > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":true,"repo":"owner/target","head_sha":"targetsha","verified_head_sha":"targetsha"}}\n' \
  > "$TARGET_REPO/.claude/state/pr-review-lock.json"
expect_allow \
  "block-merge hook accepts target repo verified lock state" \
  "block-merge-without-review.sh" \
  "gh pr merge 123 --merge --repo owner/target"

seed_target_review_ok
printf '{}\n' > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":false,"repo":"owner/target","head_sha":"oldsha"}}\n' \
  > "$TARGET_REPO/.claude/state/pr-review-lock.json"
expect_allow \
  "block-merge hook ignores stale target repo pending lock state" \
  "block-merge-without-review.sh" \
  "gh pr merge 123 --merge --repo owner/target"

seed_target_review_ok
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
