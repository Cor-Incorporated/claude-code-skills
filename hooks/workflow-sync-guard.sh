#!/bin/bash
# workflow-sync-guard.sh — PostToolUse hook for git push
# Detects when workflow files are pushed to non-main branches
# and warns that main must be synced for OIDC validation to work.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check git push commands
if ! echo "$cmd" | grep -qE 'git\s+push'; then
    exit 0
fi

# Get the branch being pushed
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -z "$project_root" ] && exit 0

current_branch=$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -z "$current_branch" ] && exit 0

# Skip if pushing to main
if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    exit 0
fi

# Check if any workflow files are in the diff vs main
default_branch="main"
workflow_changes=$(git -C "$project_root" diff --name-only "${default_branch}..HEAD" -- '.github/workflows/' 2>/dev/null || echo "")

if [ -n "$workflow_changes" ]; then
    echo "" >&2
    echo "⚠️  [WORKFLOW SYNC REQUIRED]" >&2
    echo "The following workflow files differ from '${default_branch}':" >&2
    echo "$workflow_changes" | while read -r f; do
        echo "  - $f" >&2
    done
    echo "" >&2
    echo "Claude Code Action OIDC validation requires workflow files to match" >&2
    echo "the default branch (${default_branch}) EXACTLY. Without syncing:" >&2
    echo "  → claude-review will fail on ALL PRs" >&2
    echo "" >&2
    echo "Action: Create a chore PR to sync these files to '${default_branch}':" >&2
    echo "  git checkout -b chore/sync-workflows ${default_branch}" >&2
    echo "  git show ${current_branch}:.github/workflows/<file> > .github/workflows/<file>" >&2
    echo "  git commit && git push && gh pr create --base ${default_branch}" >&2
    echo "" >&2
fi

exit 0
