#!/bin/bash
# pr-guard.sh — Consolidated PreToolUse hook for gh pr create
# BLOCKING: PR must target develop. main is forbidden.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

cmd_first_line=$(echo "$cmd" | head -1)
if ! echo "$cmd_first_line" | grep -q 'gh.*pr.*create'; then
    exit 0
fi

WARNINGS=()
BLOCKERS=()
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# --- 0. BLOCK: PR must target develop, never main ---
if echo "$cmd" | grep -q '\-\-base main'; then
    BLOCKERS+=("[BLOCK] PRのターゲットがmainです。--base develop を使ってください。main ← develop ← feat/*")
elif echo "$cmd" | grep -q '\-\-base develop'; then
    : # OK
else
    BLOCKERS+=("[BLOCK] --base が未指定です。明示的に --base develop を指定してください")
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
    WARNINGS+=("[Review] Codex レビュー記載なし。mcp__codex__codex でレビュー実施を推奨")
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
