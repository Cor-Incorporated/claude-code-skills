#!/usr/bin/env bash
# Phase 16 T16-2: Codex foreign PR truth table.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/codex/protect-branches-codex.sh"
TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
LEDGER="$TMP_DIR/guard-ledger.jsonl"
export AIDD_LEDGER_SOURCE=test

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:Cor-Incorporated/claude-code-skills.git

actual_for() {
  local command="$1" output
  output=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}' \
    | (cd "$REPO" && CODEX_GUARD_LEDGER="$LEDGER" bash "$HOOK"))
  if printf '%s' "$output" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'block\n'
  else
    printf 'allow\n'
  fi
}

fail=0
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

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: Codex foreign PR truth table mismatches=$fail" >&2
  exit 1
fi
echo "PASS: Codex foreign PR truth table mismatches=0 false_positives=0"
