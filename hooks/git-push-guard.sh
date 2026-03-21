#!/bin/bash
# git-push-guard.sh — Consolidated PreToolUse hook for git push
# Combines: enforce-push-strategy + enforce-cicd-setup
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# --- 1. Protected branch check ---
for branch in develop main master; do
    if echo "$cmd" | grep -qE "git\s+push\s+.*\b${branch}\b" && \
       ! echo "$cmd" | grep -qE "(--delete|:${branch})"; then
        push_target=$(echo "$cmd" | grep -oE "push\s+[^|;&]*" | sed 's/push\s*//' | sed 's/\s*-[a-zA-Z-]*//g' | xargs)
        refspec=$(echo "$push_target" | awk '{print $NF}')
        if [ "$refspec" = "$branch" ] || echo "$refspec" | grep -qE ":${branch}$"; then
            echo "[BLOCKED] Direct push to '${branch}'. Use PR instead." >&2
            echo "  git push -u origin feat/xxx && gh pr create --base develop" >&2
            exit 2
        fi
    fi
done

# --- 2. Local CI check before push (AP-10 prevention) ---
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$project_root" ]; then
    ci_failed=false

    # Backend checks (if backend dir exists)
    if [ -d "$project_root/backend" ]; then
        if command -v ruff >/dev/null 2>&1; then
            if ! ruff check "$project_root/backend" --quiet 2>/dev/null; then
                echo "[BLOCKED] ruff check failed. Fix lint errors before pushing." >&2
                ci_failed=true
            fi
        fi
        if command -v black >/dev/null 2>&1; then
            if ! black --check --quiet "$project_root/backend" 2>/dev/null; then
                echo "[BLOCKED] black --check failed. Run: black backend/" >&2
                ci_failed=true
            fi
        fi
    fi

    # Frontend checks (if frontend dir exists)
    if [ -d "$project_root/frontend" ]; then
        if [ -f "$project_root/frontend/package.json" ]; then
            if command -v pnpm >/dev/null 2>&1; then
                if ! (cd "$project_root/frontend" && pnpm lint --quiet 2>/dev/null); then
                    echo "[BLOCKED] pnpm lint failed. Fix lint errors before pushing." >&2
                    ci_failed=true
                fi
            fi
        fi
    fi

    if [ "$ci_failed" = true ]; then
        echo "" >&2
        echo "Local CI must pass before push. Fix the above errors first." >&2
        exit 2
    fi

    # CI/CD setup warning
    workflows_dir="$project_root/.github/workflows"
    if [ ! -d "$workflows_dir" ] || [ -z "$(ls -A "$workflows_dir" 2>/dev/null)" ]; then
        echo "[WARNING] .github/workflows/ が見つかりません。CI/CD設定を推奨。" >&2
    fi
fi

echo "$input"
