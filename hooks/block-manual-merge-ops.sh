#!/bin/bash
# block-manual-merge-ops.sh — BLOCK cherry-pick, merge, rebase commands
# These operations consume too much context. Delegate to Codex CLI instead.
#
# EXCEPTIONS (allowed without delegation):
#   - --abort operations (cleanup)
#   - Fast-forward merges from main/master into feature branches (daily sync)
#   - git merge main/master/develop with --no-edit (routine sync)
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
CMD_FIRST=$(echo "$cmd" | head -1)

# Allow --abort operations (cleanup is OK)
if echo "$CMD_FIRST" | grep -qE 'git\s+(merge|cherry-pick|rebase)\s+--abort'; then
    exit 0
fi

# Allow: git merge main/master/develop (routine branch sync)
# These are daily operations that rarely cause conflicts and don't need Codex delegation
if echo "$CMD_FIRST" | grep -qE 'git\s+merge\s+(origin/)?(main|master|develop)\b'; then
    exit 0
fi

# Allow: git rebase main/master/develop (routine branch sync)
if echo "$CMD_FIRST" | grep -qE 'git\s+rebase\s+(origin/)?(main|master|develop)\b'; then
    exit 0
fi

# Allow: git pull (which internally does fetch+merge)
if echo "$CMD_FIRST" | grep -qE 'git\s+pull\b'; then
    exit 0
fi

# BLOCK: git branch -m/-M (rename) and -f/-F (force move) — prevents commit guard bypass
# Ref: Issue #10 — AI self-bypass via branch rename (2026-03-22)
# -m/-M: rename branch to bypass prefix-based guards
# -f/-F: force-set branch pointer to move commits across branches
if echo "$CMD_FIRST" | grep -qE 'git\s+branch\s+-[mMfF]\b'; then
    echo "[BLOCK] ブランチポインタの操作はコミットガードのバイパスにつながるため禁止。" >&2
    echo "理由: -m (rename) / -f (force move) でコミット制限を回避できてしまう。" >&2
    echo "正しい方法: subagent/TeamCreate でfeatureブランチにcommitしてください。" >&2
    exit 2
fi

# BLOCK: git cherry-pick (still risky — conflict-prone)
if echo "$CMD_FIRST" | grep -qE 'git\s+cherry-pick\b'; then
    echo "[BLOCK] cherry-pickは自力で実行しない。Codex CLI経路Cに委任してください。" >&2
    echo "理由: cherry-pickはコンフリクト解消でコンテキストを大量消費する。" >&2
    exit 2
fi

# BLOCK: git merge <arbitrary-branch> (non-mainline merge)
if echo "$CMD_FIRST" | grep -qE 'git\s+merge\b'; then
    echo "[BLOCK] 任意ブランチのmergeはCodex CLI経路Cに委任してください。" >&2
    echo "理由: マージコンフリクト解消でコンテキストを大量消費する。" >&2
    echo "💡 main/master/develop からの同期mergeは許可されています。" >&2
    exit 2
fi

# BLOCK: git rebase <arbitrary-branch> (non-mainline rebase)
if echo "$CMD_FIRST" | grep -qE 'git\s+rebase\b'; then
    echo "[BLOCK] 任意ブランチのrebaseはCodex CLI経路Cに委任してください。" >&2
    echo "理由: リベースはコンフリクト解消でコンテキストを大量消費する。" >&2
    echo "💡 main/master/develop からの同期rebaseは許可されています。" >&2
    exit 2
fi

exit 0
