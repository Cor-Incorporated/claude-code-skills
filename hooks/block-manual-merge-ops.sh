#!/bin/bash
# block-manual-merge-ops.sh — BLOCK cherry-pick, merge, rebase commands
# These operations consume too much context. Delegate to Codex CLI instead.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Allow merge --abort (cleanup is OK)
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+merge\s+--abort'; then
    echo "$input"
    exit 0
fi

# Allow cherry-pick --abort
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+cherry-pick\s+--abort'; then
    echo "$input"
    exit 0
fi

# Allow rebase --abort
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+rebase\s+--abort'; then
    echo "$input"
    exit 0
fi

# BLOCK: git cherry-pick
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+cherry-pick\b'; then
    echo "[BLOCK] cherry-pickは自力で実行しない。Codex CLI経路Cに委任してください。" >&2
    echo "理由: cherry-pickはコンフリクト解消でコンテキストを大量消費する。" >&2
    exit 2
fi

# BLOCK: git merge (except --abort)
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+merge\b'; then
    echo "[BLOCK] mergeは自力で実行しない。Codex CLI経路Cに委任してください。" >&2
    echo "理由: マージコンフリクト解消でコンテキストを大量消費する。" >&2
    exit 2
fi

# BLOCK: git rebase (except --abort)
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+rebase\b'; then
    echo "[BLOCK] rebaseは自力で実行しない。Codex CLI経路Cに委任してください。" >&2
    echo "理由: リベースはコンフリクト解消でコンテキストを大量消費する。" >&2
    exit 2
fi

echo "$input"
exit 0
