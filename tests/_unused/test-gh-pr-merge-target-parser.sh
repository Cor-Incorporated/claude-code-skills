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

run_unparsed_guard() {
  local command="$1"
  HOME="$TMP_HOME" bash -c "source '$ROOT/hooks/gate-modes/common.sh' >/dev/null 2>&1; c=\$(count_gh_pr_merge_invocations \"\$1\"); if should_block_unparsed_pr_merge \"\$1\" \"\$c\"; then echo block; else echo allow; fi" _ "$command"
}

run_count() {
  local command="$1"
  HOME="$TMP_HOME" bash -c "source '$ROOT/hooks/gate-modes/common.sh' >/dev/null 2>&1; count_gh_pr_merge_invocations \"\$1\"" _ "$command"
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

assert_count_eq() {
  local desc="$1" expected="$2" command="$3" actual
  actual="$(run_count "$command")"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

assert_guard_eq() {
  local desc="$1" expected="$2" command="$3" actual
  actual="$(run_unparsed_guard "$command")"
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

assert_eq "short author email flag before target" "123" \
  "gh pr merge -A reviewer@example.com 123 --merge --repo owner/repo"

assert_eq "repo equals form before target" "123" \
  "gh pr merge --repo=owner/repo 123 --merge"

assert_eq "pull URL target is explicit and unsafe" "__NON_NUMERIC__:https://github.com/owner/repo/pull/123" \
  "gh pr merge https://github.com/owner/repo/pull/123 --merge"

assert_eq "bash -c numeric target is detected" "123" \
  "bash -c 'gh pr merge 123 --merge --repo owner/repo'"

assert_eq "nested echo mentioning merge is ignored" "" \
  "bash -c 'echo gh pr merge 123'"

assert_eq "read-only process substitution mentioning merge is ignored" "" \
  "cat <(echo gh pr merge 123)"

assert_eq "bash -lc PR URL target is explicit and unsafe" "__NON_NUMERIC__:https://github.com/owner/repo/pull/123" \
  "bash -lc 'gh pr merge https://github.com/owner/repo/pull/123 --merge'"

assert_eq "eval numeric target is detected" "123" \
  "eval 'gh pr merge 123 --merge --repo owner/repo'"

assert_eq "env split-string numeric target is detected" "123" \
  "env -S 'gh pr merge 123 --merge --repo owner/repo'"

assert_eq "env long split-string numeric target is detected" "123" \
  "env --split-string='gh pr merge 123 --merge --repo owner/repo'"

assert_eq "implicit current-branch target" "" \
  "gh pr merge --merge --repo owner/repo"

assert_eq "implicit target with stderr redirect stays implicit" "" \
  "gh pr merge --merge --repo owner/repo 2>/dev/null"

assert_eq "implicit target with stdout redirect stays implicit" "" \
  "gh pr merge --merge --repo owner/repo >/tmp/out"

assert_eq "redirect before explicit target is skipped" "123" \
  "gh pr merge --repo owner/repo >/tmp/out 123 --merge"

assert_eq "stderr redirect before explicit target is skipped" "123" \
  "gh pr merge --merge 2>/tmp/err 123 --repo owner/repo"

assert_eq "repo equals with attached redirect before target is skipped" "123" \
  "gh pr merge --repo=owner/repo>/tmp/out 123 --merge"

assert_eq "body-file process substitution before target is skipped" "123" \
  "gh pr merge --body-file <(printf ok) 123 --merge --repo owner/repo"

assert_eq "body-file equals process substitution before target is skipped" "123" \
  "gh pr merge --body-file=<(printf ok) 123 --merge --repo owner/repo"

assert_eq "body-file shell-executor pipeline before target is fail-closed" "__NON_NUMERIC__:(" \
  "gh pr merge --body-file <(printf ok|bash|eval) 123 --merge --repo owner/repo"

assert_eq "process substitution command substitution merge is detected" "123" \
  "cat <(echo \$(gh pr merge 123 --merge --repo owner/repo))"

assert_count_eq "process substitution command substitution merge is counted" "1" \
  "cat <(echo \$(gh pr merge 123 --merge --repo owner/repo))"

assert_eq "quoted process substitution command substitution merge is detected" "123" \
  'cat <(echo "$(gh pr merge 123 --merge --repo owner/repo)")'

assert_count_eq "quoted process substitution command substitution merge is counted" "1" \
  'cat <(echo "$(gh pr merge 123 --merge --repo owner/repo)")'

assert_eq "process substitution backtick merge is detected" "123" \
  'cat <(echo `gh pr merge 123 --merge --repo owner/repo`)'

assert_count_eq "process substitution backtick merge is counted" "1" \
  'cat <(echo `gh pr merge 123 --merge --repo owner/repo`)'

assert_eq "quoted process substitution backtick merge is detected" "123" \
  'cat <(echo "`gh pr merge 123 --merge --repo owner/repo`")'

assert_count_eq "quoted process substitution backtick merge is counted" "1" \
  'cat <(echo "`gh pr merge 123 --merge --repo owner/repo`")'

assert_guard_eq "quoted runtime command substitution dynamic eval merge is fail-closed" "block" \
  'echo "$(m=gh\ pr\ merge\ 123\ --merge\ --repo\ owner/repo; eval "$m")"'

assert_guard_eq "quoted runtime backtick dynamic eval merge is fail-closed" "block" \
  'echo "`m=gh\ pr\ merge\ 123\ --merge\ --repo\ owner/repo; eval "$m"`"'

assert_guard_eq "shell payload parseable command substitution merge is not pre-blocked" "allow" \
  'bash -c '\''echo "$(gh pr merge 123 --merge --repo owner/repo)"'\'''

assert_guard_eq "single-quoted command substitution literal is not pre-blocked" "allow" \
  "bash -c 'echo '\\''\$(gh pr merge 123 --merge --repo owner/repo)'\\'''"

assert_guard_eq "process-substitution input hidden env merge plus visible merge is fail-closed" "block" \
  "env m='gh pr merge 999 --merge --repo owner/repo' bash -c '\$m' < <(printf x); gh pr merge 123 --merge --repo owner/repo"

assert_guard_eq "process-substitution output hidden env merge plus visible merge is fail-closed" "block" \
  "env m='gh pr merge 999 --merge --repo owner/repo' bash -c '\$m' > >(cat); gh pr merge 123 --merge --repo owner/repo"

assert_eq "leading process-substitution redirection before merge keeps target" "999" \
  "< <(printf x); gh pr merge 999 --merge --repo owner/repo"

assert_count_eq "leading process-substitution redirection before merge is counted once" "1" \
  "< <(printf x); gh pr merge 999 --merge --repo owner/repo"

assert_eq "body-file direct process substitution hidden merge plus visible merge is unsafe" "__MULTIPLE__" \
  "gh pr merge --body-file <(gh pr merge 999 --merge --repo owner/repo) 123 --merge --repo owner/repo"

assert_count_eq "body-file direct process substitution hidden merge plus visible merge is counted" "2" \
  "gh pr merge --body-file <(gh pr merge 999 --merge --repo owner/repo) 123 --merge --repo owner/repo"

assert_eq "body-file generated shell merge is fail-closed" "__NON_NUMERIC__:(" \
  "gh pr merge --body-file <(printf 'gh pr merge 999 --merge --repo owner/repo' | bash) 123 --merge --repo owner/repo"

assert_eq "runtime command substitution hidden merge plus visible merge is unsafe" "__MULTIPLE__" \
  'echo "$(gh pr merge 123 --merge --repo owner/repo)"; gh pr merge 999 --merge --repo owner/repo'

assert_count_eq "runtime command substitution hidden merge plus visible merge is counted" "2" \
  'echo "$(gh pr merge 123 --merge --repo owner/repo)"; gh pr merge 999 --merge --repo owner/repo'

assert_eq "body-file command substitution hidden merge plus visible merge is unsafe" "__MULTIPLE__" \
  "gh pr merge --body-file <(printf %s \$(gh pr merge 999 --merge --repo owner/repo)) 123 --merge --repo owner/repo"

assert_count_eq "body-file command substitution hidden merge plus visible merge is counted" "2" \
  "gh pr merge --body-file <(printf %s \$(gh pr merge 999 --merge --repo owner/repo)) 123 --merge --repo owner/repo"

assert_eq "body-file readonly process substitution literal bash is skipped" "123" \
  "gh pr merge --body-file <(printf bash) 123 --merge --repo owner/repo"

assert_eq "body-file readonly process substitution literal eval is skipped" "123" \
  "gh pr merge --body-file <(printf eval) 123 --merge --repo owner/repo"

assert_eq "nested process substitution merge is detected" "123" \
  "cat <(head -n1 <(gh pr merge 123 --merge --repo owner/repo))"

assert_count_eq "nested process substitution merge is counted" "1" \
  "cat <(head -n1 <(gh pr merge 123 --merge --repo owner/repo))"

assert_eq "non-numeric target is explicit and unsafe" "__NON_NUMERIC__:feature/foo" \
  "gh pr merge --repo owner/repo feature/foo --merge"

assert_eq "multiple merge invocations are unsafe" "__MULTIPLE__" \
  "gh pr merge 123 --merge --repo owner/repo && gh pr merge 999 --merge --repo owner/repo"

assert_eq "multiple multiline merge invocations are unsafe" "__MULTIPLE__" \
  $'gh pr merge 123 --merge --repo owner/repo\ngh pr merge 999 --merge --repo owner/repo'

assert_eq "merge after first line is still detected" "999" \
  $'true\ngh pr merge 999 --merge --repo owner/repo'

assert_eq "absolute gh path is detected" "123" \
  "/opt/homebrew/bin/gh pr merge 123 --merge --repo owner/repo"

assert_eq "global short repo flag before pr is detected" "123" \
  "gh -R owner/repo pr merge 123 --merge"

assert_eq "global repo flag before pr is detected" "123" \
  "gh --repo owner/repo pr merge 123 --merge"

assert_eq "absolute gh path with global repo flag is detected" "123" \
  "/opt/homebrew/bin/gh -R owner/repo pr merge 123 --merge"

assert_eq "quoted heredoc-looking literal before merge stays conservative" "123" \
  $'echo "<<EOF"\ngh pr merge 123 --merge --repo owner/repo'

assert_eq "here-string-looking literal before merge stays conservative" "123" \
  $'cat <<< "text"\ngh pr merge 123 --merge --repo owner/repo'

assert_eq "heredoc body literal is conservatively detected" "123" \
  $'cat <<\'EOF\'\ngh pr merge 123 --merge --repo owner/repo\nEOF'

assert_eq "merge before heredoc body is still detected" "123" \
  $'gh pr merge 123 --merge --repo owner/repo <<\'EOF\'\nconfirmation text\nEOF'

assert_eq "ordinary heredoc body remains conservative" "123" \
  $'cat <<\'EOF\'\n\tEOF\ngh pr merge 123 --merge --repo owner/repo\nEOF'

assert_eq "dash heredoc body remains conservative" "123" \
  $'cat <<-\'EOF\'\n\tEOF\ngh pr merge 123 --merge --repo owner/repo'

echo "=== unparsed merge fallback guard ==="

assert_guard_eq "escaped dynamic eval merge is fail-closed" "block" \
  "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "escaped dynamic bash -c merge is fail-closed" "block" \
  "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; bash -c \"\$m\""

assert_guard_eq "escaped dynamic absolute bash -c merge is fail-closed" "block" \
  "m=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; /bin/bash -c \"\$m\""

assert_guard_eq "nested shell escaped dynamic eval merge is fail-closed" "block" \
  "bash -c 'm=gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\"'"

assert_guard_eq "env-wrapped escaped dynamic eval merge is fail-closed" "block" \
  "m=env\\ gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "env unset wrapped escaped dynamic eval merge is fail-closed" "block" \
  "m=env\\ -u\\ GH_TOKEN\\ gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "env assignment shell payload merge is fail-closed" "block" \
  "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'"

assert_guard_eq "env assignment hidden merge plus visible merge is fail-closed" "block" \
  "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "redirected env assignment hidden merge plus visible merge is fail-closed" "block" \
  "2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "sudo redirected env assignment hidden merge plus visible merge is fail-closed" "block" \
  "sudo 2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "nested redirected env assignment hidden merge plus visible merge is fail-closed" "block" \
  "bash -c \"2>/dev/null env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo\""

assert_guard_eq "process-substitution input hidden merge plus visible merge is fail-closed" "block" \
  "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m' < <(printf x); gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "process-substitution output hidden merge plus visible merge is fail-closed" "block" \
  "env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m' > >(cat); gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "here-string redirected env assignment hidden merge plus visible merge is fail-closed" "block" \
  "<<<x env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "noclobber redirected env assignment hidden merge plus visible merge is fail-closed" "block" \
  ">|/tmp/out env m='gh pr merge 123 --merge --repo owner/repo' bash -c '\$m'; gh pr merge 456 --merge --repo owner/repo"

assert_guard_eq "command-wrapped escaped dynamic eval merge is fail-closed" "block" \
  "m=command\\ gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "sudo-wrapped escaped dynamic eval merge is fail-closed" "block" \
  "m=sudo\\ gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "sudo user wrapped escaped dynamic eval merge is fail-closed" "block" \
  "m=sudo\\ -u\\ nobody\\ gh\\ pr\\ merge\\ 123\\ --merge\\ --repo\\ owner/repo; eval \"\$m\""

assert_guard_eq "PR comment body mentioning merge is allowed" "allow" \
  "bash -c 'gh pr comment 123 --body merge'"

assert_guard_eq "nested PR comment body mentioning merge is allowed" "allow" \
  "bash -c 'bash -c \"gh pr comment 123 --body merge\"'"

assert_guard_eq "git merge-base after PR view is allowed" "allow" \
  "bash -c 'gh pr view 123'; git merge-base HEAD origin/main"

assert_guard_eq "echo merge after PR view is allowed" "allow" \
  "bash -c 'gh pr view 123 --json title' && echo merge"

echo "gh pr merge target parser tests passed."
