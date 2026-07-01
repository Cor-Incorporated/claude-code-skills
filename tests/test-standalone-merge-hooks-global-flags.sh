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
OUT_FILE="$TMP_DIR/standalone_merge_hook.out"
ERR_FILE="$TMP_DIR/standalone_merge_hook.err"
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
          *'test("claude-review"'*) printf '%s\n' "${FAKE_CLAUDE_REVIEW_CI:-success}" ;;
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
      file="${FAKE_CHANGED_FILE:-docs/README.md}"
      if [[ -n "$jq_expr" ]]; then
        printf '%s\n' "$file"
      else
        printf '[{"filename":"%s"}]\n' "$file"
      fi
      exit 0
      ;;
    repos/owner/repo/pulls/123/comments|repos/owner/repo/issues/123/comments)
      if [[ "${FAKE_REVIEW_COMMENTS:-}" == "high" ]]; then
        if [[ "$jq_expr" == "length" ]]; then
          printf '1\n'
        elif [[ -n "$jq_expr" ]]; then
          printf '[HIGH] stale Tier 1 must not bypass this finding\n'
        else
          printf '[{"body":"[HIGH] stale Tier 1 must not bypass this finding"}]\n'
        fi
        exit 0
      fi
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
  ) >"$OUT_FILE" 2>"$ERR_FILE"
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
    cat "$ERR_FILE" >&2 || true
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
  ) >"$OUT_FILE" 2>"$ERR_FILE"
  local rc=$?
  set -e

  if [[ "$rc" -eq 2 ]] && grep -q "PR番号が特定できません" "$ERR_FILE"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not fail closed for PR URL target (exit $rc)" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat "$ERR_FILE" >&2 || true
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
  ) >"$OUT_FILE" 2>"$ERR_FILE"
  local rc=$?
  set -e

  if [[ "$rc" -eq 2 ]] && grep -q "PR番号が特定できません" "$ERR_FILE"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not fail closed for wrapped PR URL target (exit $rc)" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat "$ERR_FILE" >&2 || true
  fi
}

expect_hook_blocks_dynamic_eval_target() {
  local hook="$1"
  local label="$2"
  local command="${3:-m='gh pr merge 123 --merge --repo owner/repo'; eval \"\\\$m\"}"
  : > "$GH_LOG"

  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      bash "$ROOT/hooks/$hook" <<<"$(payload "$command")"
  ) >"$OUT_FILE" 2>"$ERR_FILE"
  local rc=$?
  set -e

  if [[ "$rc" -eq 2 ]] && grep -q "安全に解析できません" "$ERR_FILE"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label did not fail closed for dynamic eval merge (exit $rc)" >&2
    echo "--- gh log ---" >&2
    cat "$GH_LOG" >&2 || true
    echo "--- stderr ---" >&2
    cat "$ERR_FILE" >&2 || true
  fi
}

write_review_status() {
  local target="$1"
  local code_sha="$2"
  local codex_sha="$3"
  mkdir -p "$(dirname "$target")"
  CODE_SHA="$code_sha" CODEX_SHA="$codex_sha" python3 - "$target" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w") as f:
    json.dump({
        "fix/test": {
            "code_review": True,
            "code_review_sha": os.environ["CODE_SHA"],
            "codex_review": True,
            "codex_review_sha": os.environ["CODEX_SHA"],
        }
    }, f)
PY
}

reset_review_state() {
  rm -rf "$TMP_REPO/.claude" "$TMP_HOME/.claude"
  mkdir -p "$TMP_REPO/.claude/state" "$TMP_HOME/.claude/state"
}

expect_review_sha_guard() {
  local label="$1"
  local expected="$2"
  local code_sha="$3"
  local codex_sha="$4"
  reset_review_state
  write_review_status "$TMP_REPO/.claude/state/review-status.json" "$code_sha" "$codex_sha"
  : > "$GH_LOG"

  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" \
      FAKE_CHANGED_FILE="src/app.ts" FAKE_REVIEW_COMMENTS="high" FAKE_CLAUDE_REVIEW_CI="failure" \
      bash "$ROOT/hooks/block-merge-without-review.sh" <<<"$(payload 'gh pr merge 123 --merge --repo owner/repo')"
  ) >"$OUT_FILE" 2>"$ERR_FILE"
  local rc=$?
  set -e

  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (expected exit $expected, got $rc)" >&2
    echo "--- stderr ---" >&2
    cat "$ERR_FILE" >&2 || true
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
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks dynamic eval merge"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks dynamic eval merge"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks dynamic eval merge"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks dynamic eval merge"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks escaped dynamic eval merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks escaped dynamic eval merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks escaped dynamic eval merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks escaped dynamic eval merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks escaped dynamic bash -c merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; bash -c \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks escaped dynamic bash -c merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; bash -c \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks escaped dynamic bash -c merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; bash -c \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks escaped dynamic bash -c merge" "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; bash -c \"\\\$m\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks redirected hidden env plus visible merge" "2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks redirected hidden env plus visible merge" "2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks redirected hidden env plus visible merge" "2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks redirected hidden env plus visible merge" "2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks sudo redirected hidden env plus visible merge" "sudo 2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks sudo redirected hidden env plus visible merge" "sudo 2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks sudo redirected hidden env plus visible merge" "sudo 2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks sudo redirected hidden env plus visible merge" "sudo 2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks nested redirected hidden env plus visible merge" "bash -c \"2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo\""
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks nested redirected hidden env plus visible merge" "bash -c \"2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks nested redirected hidden env plus visible merge" "bash -c \"2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo\""
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks nested redirected hidden env plus visible merge" "bash -c \"2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo\""
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks process-substitution input hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' < <(printf x); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks process-substitution input hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' < <(printf x); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks process-substitution input hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' < <(printf x); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks process-substitution input hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' < <(printf x); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks process-substitution output hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' > >(cat); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks process-substitution output hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' > >(cat); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks process-substitution output hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' > >(cat); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks process-substitution output hidden env plus visible merge" "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m' > >(cat); gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks here-string redirected hidden env plus visible merge" "<<<x env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks here-string redirected hidden env plus visible merge" "<<<x env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks here-string redirected hidden env plus visible merge" "<<<x env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks here-string redirected hidden env plus visible merge" "<<<x env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-ci.sh" "block-merge-without-ci blocks noclobber redirected hidden env plus visible merge" ">|/tmp/out env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "enforce-soak-time.sh" "enforce-soak-time blocks noclobber redirected hidden env plus visible merge" ">|/tmp/out env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "block-merge-without-review.sh" "block-merge-without-review blocks noclobber redirected hidden env plus visible merge" ">|/tmp/out env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"
expect_hook_blocks_dynamic_eval_target "pr-merge-claude-review-gate.sh" "pr-merge-claude-review-gate blocks noclobber redirected hidden env plus visible merge" ">|/tmp/out env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\\\$m'; gh pr merge 456 --merge --repo owner/repo"

echo "=== standalone review gate SHA freshness ==="
expect_review_sha_guard "block-merge-without-review blocks stale Tier 1 review SHAs" 2 oldsha oldsha
expect_review_sha_guard "block-merge-without-review allows matching Tier 1 review SHAs" 0 abc123 abc123

rm -f "$OUT_FILE" "$ERR_FILE"
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ "$FAIL" -eq 0 ]]
