#!/bin/bash
# pr-guard.sh — Consolidated PreToolUse hook for gh pr create
# BLOCKING: PR must target develop. main is forbidden.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

# Tightened (Fix3-ext): require an ACTUAL `gh pr create` invocation — gh directly
# followed by pr followed by create with only whitespace between. This prevents a
# loose match from firing on a regex/string that merely contains the tokens.
cmd_first_line=$(echo "$cmd" | head -1)
if ! echo "$cmd_first_line" | grep -qE 'gh[[:space:]]+pr[[:space:]]+create\b'; then
    exit 0
fi

WARNINGS=()
BLOCKERS=()
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# --- 0. PR target branch check ---
# Allow --base main when: develop doesn't exist, or develop == main (in sync)
_develop_exists=$(git rev-parse --verify origin/develop >/dev/null 2>&1 && echo "yes" || echo "no")
_develop_main_same="no"
if [[ "$_develop_exists" == "yes" ]]; then
    _dev_sha=$(git rev-parse origin/develop 2>/dev/null || echo "")
    _main_sha=$(git rev-parse origin/main 2>/dev/null || echo "")
    [[ "$_dev_sha" == "$_main_sha" ]] && _develop_main_same="yes"
fi

if echo "$cmd" | grep -qE '\-\-base\s+main(\s|$)'; then
    _current=$(git branch --show-current 2>/dev/null || echo "")
    _is_release="no"
    # Allow release PR: develop → main
    [[ "$_current" == "develop" ]] && _is_release="yes"
    echo "$cmd" | grep -qE '\-\-head\s+develop(\s|$)' && _is_release="yes"

    if [[ "$_is_release" == "yes" ]]; then
        : # Release PR from develop → main: allowed
    elif [[ "$_develop_exists" == "yes" ]] && [[ "$_develop_main_same" == "no" ]]; then
        BLOCKERS+=("[BLOCK] PRのターゲットがmainです。--base develop を使ってください。main ← develop ← feat/*")
        BLOCKERS+=("  develop → main リリースPRは develop ブランチから作成してください。")
    fi
elif echo "$cmd" | grep -qE '\-\-base\s+develop(\s|$)'; then
    : # OK
else
    if [[ "$_develop_exists" == "yes" ]]; then
        BLOCKERS+=("[BLOCK] --base が未指定です。明示的に --base develop を指定してください")
    fi
fi

# --- 1. BLOCK: Issue reference with close keyword required ---
if ! echo "$cmd" | grep -qiE '(closes?|fixes?|resolves?)\s*#[0-9]+'; then
    if ! echo "$cmd" | grep -q '#[0-9]'; then
        BLOCKERS+=("[BLOCK] PR に Issue 参照がありません。bodyに Closes #XX を含めてください。Issue → PR → Merge → Issue Close のライフサイクル必須")
    else
        BLOCKERS+=("[BLOCK] Issue番号はありますがクローズキーワード(Closes/Fixes/Resolves)がありません。'Closes #XX' 形式にしてください。マージ時に自動クローズされます")
    fi
fi

# --- 2. Codex review check ---
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-$cmd}"
if ! echo "$TOOL_INPUT" | grep -qi "codex"; then
    WARNINGS+=("[Review] Codex レビュー記載なし。codex exec でレビュー実施を推奨")
fi

# --- 3. Terraform check ---
TF_CHANGED=$(git diff develop --name-only 2>/dev/null | grep "^terraform/" || true)
[ -n "$TF_CHANGED" ] && WARNINGS+=("[Terraform] Terraform変更あり。plan/apply済みか確認してください")

# --- 4. CI parity check ---
if [ -n "$project_root" ]; then
    CHANGED_FILES=$(git diff origin/develop --name-only 2>/dev/null || git diff develop --name-only 2>/dev/null || echo "")

    if echo "$CHANGED_FILES" | grep -q "^backend/" && [ -f "$project_root/backend/pyproject.toml" ]; then
        (cd "$project_root/backend" && ruff check . > /dev/null 2>&1) || WARNINGS+=("[CI] backend ruff check 失敗")
        (cd "$project_root/backend" && black --check . > /dev/null 2>&1) || WARNINGS+=("[CI] backend black --check 失敗")
    fi

    if echo "$CHANGED_FILES" | grep -q "^frontend/" && [ -f "$project_root/frontend/package.json" ]; then
        (cd "$project_root/frontend" && pnpm lint > /dev/null 2>&1) || WARNINGS+=("[CI] frontend lint 失敗")
        (cd "$project_root/frontend" && pnpm typecheck > /dev/null 2>&1) || WARNINGS+=("[CI] frontend typecheck 失敗")
    fi
fi

# --- 5. BLOCK: Conflict pre-check ---
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [ -n "$current_branch" ]; then
    merge_base=$(git merge-base HEAD origin/develop 2>/dev/null || echo "")
    if [ -n "$merge_base" ]; then
        conflicts=$(git merge-tree "$merge_base" HEAD origin/develop 2>/dev/null | grep -c "<<<<<<" || true)
        if [ "$conflicts" -gt 0 ]; then
            BLOCKERS+=("[BLOCK] developとのコンフリクトが${conflicts}件あります。Codex CLIでリベース/マージしてから再度PR作成してください")
        fi
    fi
fi

# --- Output ---
if [ ${#BLOCKERS[@]} -gt 0 ]; then
    echo "[PR Guard] ブロック:" >&2
    for b in "${BLOCKERS[@]}"; do
        echo "  - ${b}" >&2
    done
    exit 2
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo "[PR Guard] 確認事項:" >&2
    for w in "${WARNINGS[@]}"; do
        echo "  - ${w}" >&2
    done
fi

exit 0
