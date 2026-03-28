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
# Fork-aware features (#191, #192):
#   - Force push detection: blocks to origin, warns to fork remote
#   - Dynamic protected branches: adds upstream default branch
#   - Fork detection via: git remote get-url upstream
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

# --- Fork detection (#191) ---
is_fork_workflow() {
  git remote get-url upstream >/dev/null 2>&1
}

# --- Dynamic branch protection (#191) ---
extend_protected_branches() {
  if ! is_fork_workflow; then
    return
  fi
  local upstream_url upstream_repo upstream_default
  upstream_url=$(git remote get-url upstream 2>/dev/null || echo "")
  [ -z "$upstream_url" ] && return
  upstream_repo=$(echo "$upstream_url" \
    | sed -E 's#.*github\.com[:/]##;s/\.git$//')
  upstream_default=$(timeout 5 gh api "repos/${upstream_repo}" \
    --jq '.default_branch' 2>/dev/null || echo "")
  if [ -n "$upstream_default" ]; then
    if ! echo "$PROTECTED_BRANCHES" | grep -qw "$upstream_default"; then
      PROTECTED_BRANCHES="$PROTECTED_BRANCHES $upstream_default"
    fi
  fi
}

extend_protected_branches

# --- Force push detection (#192) ---
is_force_push() {
  local push_cmd="$1"
  if echo "$push_cmd" | grep -qE '(--(force|force-with-lease)\b|-f\b)'; then
    return 0
  fi
  if echo "$push_cmd" | grep -qE 'push\s+-[a-zA-Z]*f'; then
    return 0
  fi
  return 1
}

extract_push_remote() {
  local push_cmd="$1"
  # Strip 'git push', then remove all flags, take first positional arg
  echo "$push_cmd" | sed 's/git[[:space:]]*push[[:space:]]*//' \
    | sed 's/[[:space:]]*--[a-zA-Z-]*//g; s/[[:space:]]*-[a-zA-Z]//g' \
    | awk '{print $1}'
}

extract_push_branch() {
  local push_cmd="$1"
  echo "$push_cmd" | sed 's/git[[:space:]]*push[[:space:]]*//' \
    | sed 's/[[:space:]]*--[a-zA-Z-]*//g; s/[[:space:]]*-[a-zA-Z]//g' \
    | awk '{print $2}'
}

# --- Check 0: Force push guard (fork-aware) (#192) ---
if echo "$cmd" | grep -qE '\bgit\s+push\b' && is_force_push "$cmd"; then
  push_remote=$(extract_push_remote "$cmd")
  push_remote="${push_remote:-origin}"

  if is_fork_workflow; then
    # Fork workflow: block to origin (upstream), warn to fork remote
    if [ "$push_remote" = "origin" ]; then
      echo "[BLOCK] origin (upstream) への force push を検出。" >&2
      echo "  fork ワークフローでは origin への force push は禁止です。" >&2
      echo "  WHY: upstream の履歴を書き換えると他の contributor に影響します。" >&2
      echo "  FIX: force push が必要な場合は fork リモートを指定してください。" >&2
      exit 2
    else
      echo "[WARN] fork リモート '${push_remote}' への force push を検出。" >&2
      echo "  自分の fork への force push は許可しますが、注意してください。" >&2
    fi
  else
    # Non-fork: block force push to protected branches
    target_branch=$(extract_push_branch "$cmd")
    if [ -z "$target_branch" ]; then
      target_branch=$(git branch --show-current 2>/dev/null || echo "")
    fi
    for branch in $PROTECTED_BRANCHES; do
      if [ "$target_branch" = "$branch" ]; then
        echo "[BLOCK] 保護ブランチ '${branch}' への force push を検出。" >&2
        echo "  WHY: 共有ブランチの履歴書き換えは禁止です。" >&2
        echo "  FIX: feature ブランチで作業し、PR 経由でマージしてください。" >&2
        exit 2
      fi
    done
  fi
fi

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
