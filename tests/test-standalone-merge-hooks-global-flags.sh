#!/bin/bash
# Verify standalone merge hooks detect gh global flags before `pr merge`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_REPO="$TMP_DIR/repo"
TMP_BIN="$TMP_DIR/bin"
TMP_HOME="$TMP_DIR/home"
GH_LOG="$TMP_DIR/gh.log"
mkdir -p "$TMP_BIN" "$TMP_HOME/.claude/state"

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf 'root\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -qm init
git -C "$TMP_REPO" remote add origin git@github.com:owner/repo.git

cat > "$TMP_BIN/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_LOG"

if [[ "$1" == "api" ]]; then
  path="$2"
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
        ".base.ref // \"\"") printf 'develop\n' ;;
        *) printf '{"head":{"sha":"abc123","ref":"fix/test"},"base":{"ref":"develop"}}\n' ;;
      esac
      exit 0
      ;;
    repos/owner/repo/commits/abc123/check-runs)
      if [[ -n "$jq_expr" ]]; then
        case "$jq_expr" in
          *'status != "completed"'*) printf '0\n' ;;
          *'conclusion == "failure"'*) printf '0\n' ;;
          *'test("claude-review"'*) printf 'success\n' ;;
          *) printf '0\n' ;;
        esac
      else
        printf '{"check_runs":[{"name":"hook-tests","status":"completed","conclusion":"success"}]}\n'
      fi
      exit 0
      ;;
    repos/owner/repo/commits/abc123)
      printf '{"commit":{"committer":{"date":"2020-01-01T00:00:00Z"}}}\n'
      exit 0
      ;;
    repos/owner/repo/pulls/123/files)
      if [[ -n "$jq_expr" ]]; then
        printf 'docs/README.md\n'
      else
        printf '[{"filename":"docs/README.md"}]\n'
      fi
      exit 0
      ;;
    repos/owner/repo/pulls/123/comments|repos/owner/repo/issues/123/comments)
      if [[ "$jq_expr" == "length" ]]; then
        printf '0\n'
      elif [[ -n "$jq_expr" ]]; then
        printf '\n'
      else
        printf '[]\n'
      fi
      exit 0
      ;;
  esac
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf 'MERGEABLE\n'
  exit 0
fi

printf '{}\n'
SH
chmod +x "$TMP_BIN/gh"

payload() {
  jq -n --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

PASS=0
FAIL=0

expect_hook_reaches_pr() {
  local hook="$1"
  local label="$2"
  : > "$GH_LOG"

  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload 'gh -R owner/repo pr merge 123 --merge')"
  ) >/tmp/standalone_merge_hook.out 2>/tmp/standalone_merge_hook.err
  set -e

  if grep -q 'repos/owner/repo/pulls/123' "$GH_LOG"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not inspect PR #123" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat /tmp/standalone_merge_hook.err >&2 || true
  fi
}

expect_hook_blocks_url_target() {
  local hook="$1"
  local label="$2"
  : > "$GH_LOG"

  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload 'gh pr merge https://github.com/owner/repo/pull/123 --merge')"
  ) >/tmp/standalone_merge_hook.out 2>/tmp/standalone_merge_hook.err
  local rc=$?
  set -e

  if [[ "$rc" -eq 2 ]] && grep -q "PR番号が特定できません" /tmp/standalone_merge_hook.err; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not fail closed for PR URL target (exit $rc)" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat /tmp/standalone_merge_hook.err >&2 || true
  fi
}

expect_hook_blocks_wrapped_url_target() {
  local hook="$1"
  local label="$2"
  : > "$GH_LOG"

  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload "bash -c 'gh pr merge https://github.com/owner/repo/pull/123 --merge'")"
  ) >/tmp/standalone_merge_hook.out 2>/tmp/standalone_merge_hook.err
  local rc=$?
  set -e

  if [[ "$rc" -eq 2 ]] && grep -q "PR番号が特定できません" /tmp/standalone_merge_hook.err; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not fail closed for wrapped PR URL target (exit $rc)" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat /tmp/standalone_merge_hook.err >&2 || true
  fi
}

echo "=== standalone merge hooks with gh global flags ==="
expect_hook_reaches_pr "block-merge-without-ci.sh" "block-merge-without-ci detects gh -R pr merge"
expect_hook_reaches_pr "enforce-soak-time.sh" "enforce-soak-time detects gh -R pr merge"
expect_hook_reaches_pr "block-merge-without-review.sh" "block-merge-without-review detects gh -R pr merge"
expect_hook_reaches_pr "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate detects gh -R pr merge"

echo "=== standalone merge hooks with PR URL target ==="
expect_hook_blocks_url_target "block-merge-without-ci.sh" "block-merge-without-ci blocks PR URL target"
expect_hook_blocks_url_target "enforce-soak-time.sh" "enforce-soak-time blocks PR URL target"
expect_hook_blocks_url_target "block-merge-without-review.sh" "block-merge-without-review blocks PR URL target"
expect_hook_blocks_url_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks PR URL target"
expect_hook_blocks_wrapped_url_target "block-merge-without-ci.sh" "block-merge-without-ci blocks bash -c PR URL target"
expect_hook_blocks_wrapped_url_target "enforce-soak-time.sh" "enforce-soak-time blocks bash -c PR URL target"
expect_hook_blocks_wrapped_url_target "block-merge-without-review.sh" "block-merge-without-review blocks bash -c PR URL target"
expect_hook_blocks_wrapped_url_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks bash -c PR URL target"

rm -f /tmp/standalone_merge_hook.out /tmp/standalone_merge_hook.err
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
