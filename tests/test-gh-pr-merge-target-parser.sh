#!/bin/bash
# test-gh-pr-merge-target-parser.sh — gh pr merge target parsing variants

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

run_parser() {
  local command="$1"
  HOME="$TMP_HOME" bash -c "source '$ROOT/hooks/gate-modes/common.sh' >/dev/null 2>&1; extract_gh_pr_merge_target \"\$1\"" _ "$command"
}

assert_eq() {
  local desc="$1" expected="$2" command="$3" actual
  actual="$(run_parser "$command")"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

echo "=== gh pr merge target parser ==="

assert_eq "number immediately after merge" "123" \
  "gh pr merge 123 --merge --repo owner/repo"

assert_eq "repo flag before target" "123" \
  "gh pr merge --repo owner/repo 123 --merge"

assert_eq "short repo flag before target" "123" \
  "gh pr merge -R owner/repo 123 --merge"

assert_eq "repo equals form before target" "123" \
  "gh pr merge --repo=owner/repo 123 --merge"

assert_eq "pull URL target" "123" \
  "gh pr merge https://github.com/owner/repo/pull/123 --merge"

assert_eq "implicit current-branch target" "" \
  "gh pr merge --merge --repo owner/repo"

assert_eq "non-numeric target is explicit and unsafe" "__NON_NUMERIC__:feature/foo" \
  "gh pr merge --repo owner/repo feature/foo --merge"

echo "gh pr merge target parser tests passed."
