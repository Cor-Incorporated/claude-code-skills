#!/bin/bash
# git-push-guard.sh — Consolidated PreToolUse hook for git push
# Combines: enforce-push-strategy + enforce-cicd-setup
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# --- 0. Early exit: only run on git push commands (Issue #150) ---
# Without this guard, black/ruff checks in section 3 block ALL Bash commands,
# creating an unrecoverable deadlock where even `black .` is blocked.
if ! echo "$cmd" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

# --- 1. Force push to shared branches check (Issue #17) ---
# Block --force / --force-with-lease to develop/main/master
# Feature branches are allowed (user's own branch history cleanup is legitimate)
if echo "$cmd" | grep -qE 'git\s+push\b.*(--(force|force-with-lease)\b|-f\b)' || \
   echo "$cmd" | grep -qE 'git\s+push\s+-[a-zA-Z]*f'; then
    # Check explicit branch names in the command
    for branch in develop main master; do
        if echo "$cmd" | grep -qE "(^|[[:space:]])${branch}([[:space:]]|$|:)"; then
            cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出

理由: force push は履歴を書き換えます。
  - 他のエンジニアの作業ベースが壊れる可能性
  - レビュー済みコミット履歴が失われる可能性
  - --force-with-lease も --force と同等に扱います

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #17 — AI からの force push はブロック、ユーザー手動実行に限定
ERRMSG
            exit 2
        fi
    done

    # Fallback: if no explicit branch in command, check current branch
    # Catches: git push --force, git push --force origin (implicit branch)
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    for branch in develop main master; do
        if [[ "$current_branch" == "$branch" ]]; then
            cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出（暗黙的ブランチ）

現在のブランチ '${branch}' は共有ブランチです。
コマンドにブランチ名が明示されていなくても、force push はブロックされます。

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #28 — 差分有無にかかわらず共有ブランチへの force push をブロック
ERRMSG
            exit 2
        fi
    done
fi

# --- 2. Protected branch direct push check ---
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

# --- 3. Local CI check before push (AP-10 prevention) ---
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

exit 0
