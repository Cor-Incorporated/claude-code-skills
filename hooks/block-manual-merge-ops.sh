#!/bin/bash
# block-manual-merge-ops.sh — BLOCK cherry-pick, merge, rebase commands
# These operations consume too much context. Delegate to Codex CLI instead.
#
# EXCEPTIONS (allowed without delegation):
#   - --abort operations (cleanup)
#   - --continue for permitted rebase sessions (tracked via state file)
#   - Fast-forward merges from main/master into feature branches (daily sync)
#   - git merge main/master/develop with --no-edit (routine sync)
#
# Rebase session tracking (Issue #16):
#   When a sync rebase (origin/main|master|develop) is permitted, a state file
#   records the session. --continue is allowed only when this state exists.
#   The state file is protected by block-state-file-tampering.sh.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
CMD_FIRST=$(echo "$cmd" | head -1)

# --- State file for rebase session tracking ---
REBASE_STATE_FILE="${HOME}/.claude/state/rebase-session.json"
mkdir -p "$(dirname "$REBASE_STATE_FILE")"

_write_rebase_state() {
    local target="$1"
    local now_epoch
    now_epoch=$(date +%s)
    cat > "$REBASE_STATE_FILE" <<EOJSON
{"rebase_in_progress":true,"rebase_target":"${target}","started_epoch":${now_epoch}}
EOJSON
}

_clear_rebase_state() {
    rm -f "$REBASE_STATE_FILE"
}

_check_rebase_state() {
    if [ ! -f "$REBASE_STATE_FILE" ]; then
        return 1
    fi
    local in_progress
    in_progress=$(jq -r '.rebase_in_progress // false' "$REBASE_STATE_FILE" 2>/dev/null || echo "false")
    if [ "$in_progress" != "true" ]; then
        return 1
    fi
    # Expire after 1 hour to prevent stale state
    local started_epoch now_epoch
    started_epoch=$(jq -r '.started_epoch // 0' "$REBASE_STATE_FILE" 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [ $((now_epoch - started_epoch)) -gt 3600 ]; then
        echo "[INFO] rebase session expired (>1h). Clearing stale state." >&2
        _clear_rebase_state
        return 1
    fi
    return 0
}

# Allow --abort operations (cleanup is OK) + clear rebase state
if echo "$CMD_FIRST" | grep -qE 'git\s+(merge|cherry-pick)\s+--abort'; then
    exit 0
fi
if echo "$CMD_FIRST" | grep -qE 'git\s+rebase\s+--abort'; then
    _clear_rebase_state
    exit 0
fi

# Allow: git rebase --continue (only if a permitted rebase session is active)
# Ref: Issue #16 — rebase --continue was blocked after permitted sync rebase
if echo "$CMD_FIRST" | grep -qE 'git\s+rebase\s+--continue'; then
    if _check_rebase_state; then
        local_target=$(jq -r '.rebase_target // "unknown"' "$REBASE_STATE_FILE" 2>/dev/null || echo "unknown")
        echo "[ALLOW] rebase --continue: 許可済み同期rebase (target: ${local_target}) の完了。" >&2
        _clear_rebase_state
        exit 0
    else
        echo "[BLOCK] rebase --continue: 許可済みrebaseセッションが見つかりません。" >&2
        echo "理由: --continue は直前に許可された同期rebase (origin/main|master|develop) の" >&2
        echo "      完了操作にのみ許可されます。任意ブランチのrebase完了はCodex CLIに委任。" >&2
        exit 2
    fi
fi

# Allow: git merge main/master/develop (routine branch sync)
# These are daily operations that rarely cause conflicts and don't need Codex delegation
if echo "$CMD_FIRST" | grep -qE 'git\s+merge\s+(origin/)?(main|master|develop)\b'; then
    exit 0
fi

# Allow: git rebase main/master/develop (routine branch sync) + record state
if echo "$CMD_FIRST" | grep -qE 'git\s+rebase\s+(origin/)?(main|master|develop)\b'; then
    # Extract the target (e.g., "origin/main", "develop")
    rebase_target=$(echo "$CMD_FIRST" | grep -oE '(origin/)?(main|master|develop)' | head -1)
    _write_rebase_state "$rebase_target"
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
if echo "$CMD_FIRST" | grep -qE 'git\s+branch\s+(-[mMfF]\b|--move\b|--force\b)'; then
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
