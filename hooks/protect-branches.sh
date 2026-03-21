#!/bin/bash
# =============================================================================
# Protected Branch Guard Hook
# =============================================================================
# Prevents deletion of protected branches (develop, main, master) via:
#   - gh pr merge --delete-branch (checks PR source branch)
#   - git branch -d/-D <protected>
#   - git push origin --delete <protected>
#   - git push origin :<protected>
#
# Usage: PreToolUse hook in ~/.claude/settings.json
# Input: JSON on stdin with tool_input.command
# Exit codes:
#   0 = allow (outputs JSON unchanged)
#   2 = block (stderr message shown to user)
# =============================================================================

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

PROTECTED_BRANCHES="develop main master"

# --- Check 1: Direct branch deletion (git branch -d/-D) ---
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd" | grep -qE "git\s+branch\s+-[dD]\s+.*\b${branch}\b"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted locally." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        exit 2
    fi
done

# --- Check 2: Remote branch deletion (git push --delete) ---
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd" | grep -qE "push\s+.*--delete\s+.*\b${branch}\b"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted from remote." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        exit 2
    fi
done

# --- Check 3: Remote branch deletion (git push origin :branch) ---
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd" | grep -qE "push\s+\S+\s+:${branch}(\s|$)"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted from remote." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        exit 2
    fi
done

# --- Check 4: gh pr merge --delete-branch (most dangerous!) ---
if echo "$cmd" | grep -qE 'gh\s+pr\s+merge.*--delete-branch'; then
    PR_CHECKED=false

    # Extract PR number
    PR_NUM=$(echo "$cmd" | grep -oE 'merge\s+[0-9]+' | grep -oE '[0-9]+' || echo "")

    if [ -n "$PR_NUM" ]; then
        # Query the PR's source (head) branch
        HEAD_BRANCH=$(gh pr view "$PR_NUM" --json headRefName -q '.headRefName' 2>/dev/null || echo "")

        if [ -n "$HEAD_BRANCH" ]; then
            PR_CHECKED=true
            for branch in $PROTECTED_BRANCHES; do
                if [ "$HEAD_BRANCH" = "$branch" ]; then
                    echo "[Hook] BLOCKED: PR #${PR_NUM} source branch is '${branch}' (protected)." >&2
                    echo "[Hook] --delete-branch would delete '${branch}', which is tied to CI/CD." >&2
                    echo "[Hook] Remove --delete-branch and run: gh pr merge ${PR_NUM} --merge" >&2
                    exit 2
                fi
            done
            # PR source branch is NOT protected - allow
        fi
    fi

    # Fallback: if we couldn't determine the PR's source branch, check current branch
    if [ "$PR_CHECKED" = "false" ]; then
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
        for branch in $PROTECTED_BRANCHES; do
            if [ "$CURRENT_BRANCH" = "$branch" ]; then
                echo "[Hook] BLOCKED: Cannot determine PR source branch, and current branch '${branch}' is protected." >&2
                echo "[Hook] --delete-branch could delete a protected branch." >&2
                echo "[Hook] Remove --delete-branch flag and retry." >&2
                exit 2
            fi
        done
    fi
fi

# All checks passed - allow the command
exit 0
