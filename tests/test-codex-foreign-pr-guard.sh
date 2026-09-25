#!/usr/bin/env bash
# Phase 16 T16-2: Codex foreign PR truth table.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/codex/protect-branches-codex.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
REPO="$TMP_DIR/repo"
LEDGER="$TMP_DIR/guard-ledger.jsonl"
# The spike probe appends to ${CODEX_SPIKE_LOG:-$HOME/.codex/hooks/spike-fire.log},
# the file that proves the *real* Codex PreToolUse hook fired. This test must
# never write there. Before this fix it did: on 2026-09-24 the real log had 112
# lines, and the log alone could no longer tell a real fire from a test run.
# Every hook call pins the log to $SPIKE_LOG and runs under $SANDBOX_HOME, whose
# .codex/hooks/ exists as on a deployed machine, so a lost pin lands there and
# fails the containment check below instead of reaching the real log.
SPIKE_LOG="$TMP_DIR/spike-fire.log"
SANDBOX_HOME="$TMP_DIR/home"
export AIDD_LEDGER_SOURCE=test

mkdir -p "$REPO" "$SANDBOX_HOME/.codex/hooks"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:Cor-Incorporated/claude-code-skills.git

actual_for() {
  local command="$1" output
  output=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}' \
    | (cd "$REPO" && HOME="$SANDBOX_HOME" CODEX_GUARD_LEDGER="$LEDGER" CODEX_SPIKE_LOG="$SPIKE_LOG" bash "$HOOK"))
  if printf '%s' "$output" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'block\n'
  else
    printf 'allow\n'
  fi
}

# SPIKE_FIRED lines the probe has written to the sandbox log so far. grep -c
# prints 0 but exits 1 on no match; `|| true` keeps the function's status 0 so
# that `before="$(spike_count)"` does not trip set -e. The count is asserted.
spike_count() {
  [ -f "$SPIKE_LOG" ] || { printf '0\n'; return; }
  grep -cE '^SPIKE_FIRED [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$SPIKE_LOG" || true
}

# Set before the first axis, which adds its mismatches here. It used to be set
# after that axis, so an escape-axis mismatch died on "fail: unbound variable"
# (set -u) instead of reaching the FAIL summary.
fail=0

# --- Markdown-escape axis (2026-09-02) ---------------------------------------
# Codex Desktop passes UI text through to the hook with Markdown escaping still
# applied. The real payload observed was:
#   ["/bin/zsh","-lc","echo AIDD\_CODEX\_HOOK\_SPIKE\_MARKER"]
# A bare string comparison then fails to see `\-\-repo` as `--repo`, so the
# foreign-PR guard returned ALLOW on a command it must block.
# Falsifiable: drop the sed unescape from cmd_norm and the escaped rows go allow.
#
# probe column (2026-09-24): a spike row must also add exactly one SPIKE_FIRED
# line to the sandbox log, so "hook blocked" implies "probe fired"; every other
# row must add none. The spike rows used to pass on the deny alone, even when
# the append failed (a HOME without ~/.codex/hooks/ gave ENOENT and still PASS).
# Falsifiable: drop the SPIKE_FIRED append from the hook and both spike rows go
# FAIL with probe_actual=silent.
esc_fail=0
spike_expected=0
printf '\nescape_case\texpected\tactual\tprobe_expected\tprobe_actual\tverdict\n'
while IFS='|' read -r label command expected probe; do
  [ -z "$label" ] && continue
  before="$(spike_count)"
  actual="$(actual_for "$command")"
  after="$(spike_count)"
  case "$((after - before))" in
    0) probe_actual=silent ;;
    1) probe_actual=fired ;;
    *) probe_actual="delta=$((after - before))" ;;
  esac
  [ "$probe" = fired ] && spike_expected=$((spike_expected + 1))
  if [ "$actual" = "$expected" ] && [ "$probe_actual" = "$probe" ]; then verdict=PASS; else verdict=FAIL; esc_fail=$((esc_fail + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$expected" "$actual" "$probe" "$probe_actual" "$verdict"
  if [ "$probe_actual" != "$probe" ]; then
    printf '  sandbox spike log after %s:\n' "$label" >&2
    sed 's/^/    /' "$SPIKE_LOG" >&2 2>/dev/null || printf '    (absent)\n' >&2
  fi
done <<'CASES'
foreign-pr-escaped|gh pr create \-\-repo anomalyco/opencode \-\-base dev|block|silent
foreign-pr-plain|gh pr create --repo anomalyco/opencode --base dev|block|silent
spike-marker-escaped|echo AIDD\_CODEX\_HOOK\_SPIKE\_MARKER|block|fired
spike-marker-plain|echo AIDD_CODEX_HOOK_SPIKE_MARKER|block|fired
force-push-escaped|git push \-\-force origin main|block|silent
mirror-push-escaped|git push \-\-mirror origin|block|silent
benign-escaped|echo hello\_world|allow|silent
benign-underscore-branch|git push origin develop\_x|allow|silent
CASES
spike_table="$(spike_count)"
if [ "$esc_fail" -ne 0 ]; then
  printf 'FAIL: markdown-escape axis mismatches=%s\n' "$esc_fail"
  fail=$((fail + esc_fail))
else
  printf 'PASS: markdown-escape axis mismatches=0\n'
fi

printf 'repo_axis\toperation\texpected\tactual\tverdict\n'
for repo_axis in foreign same none; do
  for operation in create merge; do
    case "$repo_axis" in
      foreign)
        repo_arg='--repo anomalyco/opencode'
        expected=block
        ;;
      same)
        repo_arg='--repo "cor-incorporated/another-repo"'
        expected=allow
        ;;
      none)
        repo_arg=''
        expected=allow
        ;;
    esac
    command="gh pr $operation"
    [[ -n "$repo_arg" ]] && command="$command $repo_arg"
    actual=$(actual_for "$command")
    verdict=PASS
    if [[ "$actual" != "$expected" ]]; then
      verdict=FAIL
      fail=$((fail + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo_axis" "$operation" "$expected" "$actual" "$verdict"
  done
done

# Equals-form and GitHub URL are part of the same owner contract.
[[ "$(actual_for 'gh pr create --repo=anomalyco/opencode')" == block ]] || fail=$((fail + 1))
[[ "$(actual_for 'gh pr merge --repo=https://github.com/Cor-Incorporated/example.git')" == allow ]] || fail=$((fail + 1))

# --- probe containment (2026-09-25) ------------------------------------------
# The table must still hold a row that fires, or the probe column proves
# nothing. The calls after the table carry no marker, so they must add no line.
# And the hook must have created nothing under $SANDBOX_HOME besides the two
# directories made above: a default-path spike log or guard ledger there means
# a pin was lost, and on a real run that file would have been
# ~/.codex/hooks/spike-fire.log or guard-ledger.jsonl.
# Falsifiable: drop the CODEX_SPIKE_LOG pin, or make the hook also append to
# $HOME/.codex/hooks/spike-fire.log, and home_files lists that file.
spike_extra=$(($(spike_count) - spike_table))
home_files="$(cd "$SANDBOX_HOME" && find . -mindepth 1 ! -path ./.codex ! -path ./.codex/hooks | sed 's#^\./##' | tr '\n' ' ')"
if [[ "$spike_expected" -lt 1 || "$spike_extra" -ne 0 || -n "$home_files" ]]; then
  echo "FAIL: spike probe containment spike_rows=$spike_expected extra_lines=$spike_extra home_files=${home_files:-none}" >&2
  fail=$((fail + 1))
else
  echo "PASS: spike probe containment sandbox_log=$(spike_count) spike_rows=$spike_expected home_files=none"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: Codex foreign PR truth table mismatches=$fail" >&2
  exit 1
fi
echo "PASS: Codex foreign PR truth table mismatches=0 false_positives=0"
