#!/bin/bash
# Verify standalone merge hooks read review state from the command target repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SRC_REPO="$TMP_DIR/source"
TARGET_REPO="$TMP_DIR/target"
TMP_REMOTE="$TMP_DIR/remote.git"
TMP_BIN="$TMP_DIR/bin"
TMP_HOME="$TMP_DIR/home"
GH_LOG="$TMP_DIR/gh.log"
mkdir -p "$TMP_BIN" "$TMP_HOME/.claude/state"

# Real shared bare remote so pre-merge.sh base-freshness (git fetch + rev-parse)
# succeeds in both repos. BASE_SHA is exported so the gh mock can return it
# for base.sha / git/ref/heads/<ref> queries.
git init -q "$SRC_REPO"
git -C "$SRC_REPO" config user.email test@example.com
git -C "$SRC_REPO" config user.name Test
printf 'root\n' > "$SRC_REPO/README.md"
git -C "$SRC_REPO" add README.md
git -C "$SRC_REPO" commit -qm init
git -C "$SRC_REPO" branch -M develop
git clone -q --bare "$SRC_REPO" "$TMP_REMOTE"
git -C "$SRC_REPO" remote add origin "$TMP_REMOTE"
git -C "$SRC_REPO" push -q origin develop
git clone -q "$TMP_REMOTE" "$TARGET_REPO"
git -C "$TARGET_REPO" config user.email test@example.com
git -C "$TARGET_REPO" config user.name Test
mkdir -p "$SRC_REPO/.claude/state" "$TARGET_REPO/.claude/state"
BASE_SHA="$(git -C "$SRC_REPO" rev-parse develop)"
TEST_BASE_SHA="$BASE_SHA"
export TEST_BASE_SHA

cat > "$TMP_BIN/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_LOG"

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
      ".head.ref"|".head.ref // \"\"") printf 'feat/context\n' ;;
      ".base.ref"|".base.ref // \"\"") printf 'develop\n' ;;
      ".base.sha"|".base.sha // \"\"") printf '%s\n' "${TEST_BASE_SHA:-developsha}" ;;
      *) printf '{"head":{"sha":"abc123","ref":"feat/context"},"base":{"ref":"develop","sha":"%s"}}\n' "${TEST_BASE_SHA:-developsha}" ;;
    esac
    ;;
  repos/owner/repo/git/ref/heads/develop)
    if [[ "$jq_expr" == ".object.sha" ]]; then
      printf '%s\n' "${TEST_BASE_SHA:-developsha}"
    else
      printf '{"object":{"sha":"%s"}}\n' "${TEST_BASE_SHA:-developsha}"
    fi
    ;;
  repos/owner/repo/commits/abc123/check-runs)
    case "$jq_expr" in
      *'status != "completed"'*) printf '0\n' ;;
      *'conclusion == "failure"'*) printf '0\n' ;;
      *'test("claude-review"'*) printf 'success\n' ;;
      *) printf '{"check_runs":[{"name":"claude-review","status":"completed","conclusion":"success"}]}\n' ;;
    esac
    ;;
  repos/owner/repo/issues/123/comments)
    case "$jq_expr" in
      length) printf '1\n' ;;
      *'.[].body'*) printf 'LGTM\n' ;;
      *) printf '[{"body":"LGTM"}]\n' ;;
    esac
    ;;
  repos/owner/repo/pulls/123/comments)
    case "$jq_expr" in
      *'.[].body'*) printf '\n' ;;
      *) printf '[]\n' ;;
    esac
    ;;
  repos/owner/repo/pulls/123/files)
    case "$jq_expr" in
      *filename*) printf 'src/index.ts\n' ;;
      *) printf '[{"filename":"src/index.ts"}]\n' ;;
    esac
    ;;
  *)
    printf '{}\n'
    ;;
esac
SH
chmod +x "$TMP_BIN/gh"

payload() {
  jq -n --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

run_hook() {
  local hook="$1"
  local command="$2"
  case "$hook" in
    pr-merge-claude-review-gate.sh|block-merge-without-review.sh)
      # Phase 3: retired hooks consolidated into pre-merge.sh
      set +e
      (
        cd "$SRC_REPO"
        HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
          GATE_MODE=PRE_MERGE bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$(payload "$command")"
      ) >"$TMP_DIR/out" 2>"$TMP_DIR/err"
      local rc=$?
      set -e
      return "$rc"
      ;;
  esac
  set +e
  (
    cd "$SRC_REPO"
    HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload "$command")"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err"
  local rc=$?
  set -e
  return "$rc"
}

PASS=0
FAIL=0

echo "=== merge hooks target repo context ==="

printf '{"123":{"review_read":true,"fallback_review_done":true,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$SRC_REPO/.claude/state/pr-review-read.json"
printf '{}\n' > "$TARGET_REPO/.claude/state/pr-review-read.json"
if run_hook "pr-merge-claude-review-gate.sh" "cd '$TARGET_REPO' && bash -c 'gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate read source review state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on target unread state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "(cd '$TARGET_REPO' && gh pr merge 123 --merge --repo owner/repo)"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed subshell target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on subshell target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate subshell unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "cd '$TARGET_REPO' && env -u GH_TOKEN gh pr merge 123 --merge --repo owner/repo"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed env-wrapped target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on env-wrapped target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate env-wrapped unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "cd '$TARGET_REPO' && env -S 'gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed env split-string target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on env split-string target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate env split-string unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "cd '$TARGET_REPO' && env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed env assignment target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -Eq "レビューを未読|安全に解析できません" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on env assignment target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate env assignment unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "env -C '$TARGET_REPO' gh pr merge 123 --merge --repo owner/repo"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed env chdir target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on env chdir target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate env chdir unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "pr-merge-claude-review-gate.sh" "bash -c 'cd \"$TARGET_REPO\" && gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pr-merge-claude-review-gate missed nested shell target state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "レビューを未読" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-merge-claude-review-gate blocks on nested shell target state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pr-merge-claude-review-gate nested shell unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

printf '{}\n' > "$SRC_REPO/.claude/state/pr-review-lock.json"
printf '{"123":{"verified":false,"repo":"owner/repo","head_sha":"abc123"}}\n' > "$TARGET_REPO/.claude/state/pr-review-lock.json"
if run_hook "block-merge-without-review.sh" "cd '$TARGET_REPO' && bash -c 'gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review read source lock state" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on target lock state"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "(cd '$TARGET_REPO' && gh pr merge 123 --merge --repo owner/repo)"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed subshell target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on subshell target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review subshell unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "cd '$TARGET_REPO' && env -u GH_TOKEN gh pr merge 123 --merge --repo owner/repo"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed env-wrapped target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on env-wrapped target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review env-wrapped unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "cd '$TARGET_REPO' && env -S 'gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed env split-string target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on env split-string target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review env split-string unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "cd '$TARGET_REPO' && env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed env assignment target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -Eq "Pessimistic Lock|安全に解析できません" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on env assignment target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review env assignment unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "env -C '$TARGET_REPO' gh pr merge 123 --merge --repo owner/repo"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed env chdir target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on env chdir target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review env chdir unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

if run_hook "block-merge-without-review.sh" "bash -c 'cd \"$TARGET_REPO\" && gh pr merge 123 --merge --repo owner/repo'"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: block-merge-without-review missed nested shell target lock" >&2
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q "Pessimistic Lock" "$TMP_DIR/err"; then
    PASS=$((PASS + 1))
    echo "  PASS: block-merge-without-review blocks on nested shell target lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: block-merge-without-review nested shell unexpected exit $rc" >&2
    cat "$TMP_DIR/err" >&2 || true
  fi
fi

echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
