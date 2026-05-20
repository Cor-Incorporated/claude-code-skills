#!/bin/bash
# enforce-develop-base.sh — PreToolUse hook (Bash)
# =========================================================================
# Enforces develop-based branching workflow:
#   1. BLOCK: git checkout -b from main/master when develop exists
#   2. BLOCK: gh pr create targeting main when develop exists
#
# When develop branch exists, ALL feature branches must be created from
# develop, and ALL PRs must target develop (not main).
#
# Exit codes:
#   0 = allow
#   2 = block
# =========================================================================

set -uo pipefail

# Subagent exemption
[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0
[[ -n "${CLAUDE_AGENT_ID:-}" ]] && exit 0

# Only run in git repos
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

# Read stdin
input=""
[[ ! -t 0 ]] && input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[[ -z "$cmd" ]] && exit 0

# Check if develop branch exists (local or remote)
has_develop="no"
git rev-parse --verify develop >/dev/null 2>&1 && has_develop="yes"
if [[ "$has_develop" == "no" ]]; then
  git rev-parse --verify origin/develop >/dev/null 2>&1 && has_develop="yes"
fi

# If no develop branch, no enforcement needed
[[ "$has_develop" == "no" ]] && exit 0

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# =========================================================================
# Rule 1: Block branch creation from main/master
# Matches: git checkout -b <name>, git switch -c <name>
# =========================================================================
if echo "$(echo "$cmd" | head -1)" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  if [[ "$CURRENT_BRANCH" == "main" ]] || [[ "$CURRENT_BRANCH" == "master" ]]; then
    echo "" >&2
    echo "[BLOCKED] enforce-develop-base: ${CURRENT_BRANCH}からのブランチ作成を拒否。" >&2
    echo "  developブランチが存在するため、developからブランチを切ってください。" >&2
    echo "" >&2
    echo "解決方法:" >&2
    echo "  git checkout develop && git checkout -b <branch-name>" >&2
    echo "" >&2
    exit 2
  fi
fi

# =========================================================================
# Rule 2: Block PR creation targeting main when develop exists
# Matches: gh pr create (with or without --base)
# =========================================================================
if echo "$(echo "$cmd" | head -1)" | grep -qE 'gh\s+pr\s+create'; then
  # Check if --base is explicitly set
  pr_base=$(echo "$cmd" | grep -oE '\-\-base\s+\S+' | awk '{print $2}' || echo "")

  if [[ "$pr_base" == "main" ]] || [[ "$pr_base" == "master" ]]; then
    # Release PR exception: develop → main is the intended release path.
    # Allow when:
    #   (a) the current branch IS develop, or
    #   (b) --head develop is explicitly specified.
    pr_head=$(echo "$cmd" | grep -oE '\-\-head\s+\S+' | awk '{print $2}' || echo "")
    if [[ "$CURRENT_BRANCH" == "develop" ]] || [[ "$pr_head" == "develop" ]]; then
      exit 0
    fi
    echo "" >&2
    echo "[BLOCKED] enforce-develop-base: PRのターゲットが${pr_base}になっています。" >&2
    echo "  developブランチが存在するため、PRはdevelopに向けてください。" >&2
    echo "" >&2
    echo "解決方法:" >&2
    echo "  gh pr create --base develop ..." >&2
    echo "  ※ リリースPR (develop→main) は例外的に許可されます。" >&2
    echo "" >&2
    exit 2
  fi

  # If no --base specified, check if default branch is main
  # (GitHub defaults to repo's default branch, which is often main)
  if [[ -z "$pr_base" ]]; then
    # Get the repo's default branch
    repo_default=$(timeout 8 gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
    if [[ "$repo_default" == "main" ]] || [[ "$repo_default" == "master" ]]; then
      echo "" >&2
      echo "[BLOCKED] enforce-develop-base: --baseが未指定です（デフォルト: ${repo_default}）。" >&2
      echo "  developブランチが存在するため、明示的に --base develop を指定してください。" >&2
      echo "" >&2
      echo "解決方法:" >&2
      echo "  gh pr create --base develop ..." >&2
      echo "" >&2
      exit 2
    fi
  fi
fi

exit 0
