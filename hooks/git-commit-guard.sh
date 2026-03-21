#!/bin/bash
# git-commit-guard.sh — Consolidated PreToolUse hook for git commit
# Combines: enforce-commit-format + enforce-issue-reference-on-commit + enforce-zero-tolerance-precommit
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

if ! echo "$cmd" | grep -qE 'git\s+commit\s+.*-m'; then
    echo "$input"
    exit 0
fi

# --- Rule 0: Block direct commits on feature branches from main session ---
# TeamCreate workers and subagents are exempt (they SHOULD commit)
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -eq 0 ]] && [[ -z "${CLAUDE_AGENT_ID:-}" ]]; then
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    if echo "$current_branch" | grep -qE '^(feat|fix|refactor|chore)/'; then
        echo "🚫 [Delegation Required] メインエージェントはfeatureブランチに直接commitできません。" >&2
        echo "" >&2
        echo "ブランチ: $current_branch" >&2
        echo "" >&2
        echo "対応方法:" >&2
        echo "  1. TeamCreate でワーカーに委任する" >&2
        echo "  2. /review-loop で自動修正ループを起動する" >&2
        echo "  3. Agent tool (team_name付き) でワーカーに作業させる" >&2
        echo "" >&2
        echo "理由: メインが直接featureブランチで作業すると、" >&2
        echo "  未関係ファイルの混入、ruff format漏れ、コンテキスト消費が発生する。" >&2
        exit 2
    fi
fi

# --- Extract commit message ---
commit_msg=""
if echo "$cmd" | grep -qE "cat\s+<<"; then
    commit_msg=$(echo "$cmd" | awk '/<<.*EOF/{found=1; next} /EOF/{exit} found && /[a-zA-Z]/{print; exit}' | sed 's/^[[:space:]]*//')
else
    commit_msg=$(echo "$cmd" | sed -n 's/.*-m[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$commit_msg" ] && commit_msg=$(echo "$cmd" | sed -n "s/.*-m[[:space:]]*'\\([^']*\\)'.*/\\1/p" | head -1)
fi

[ -z "$commit_msg" ] && { echo "$input"; exit 0; }
commit_msg=$(echo "$commit_msg" | sed 's/^[[:space:]]*//')

# --- 1. Conventional Commit format ---
VALID_TYPES="feat|fix|refactor|docs|test|chore|perf|ci|release"
if ! echo "$commit_msg" | grep -qE "^(${VALID_TYPES})(\\(.+\\))?: .+"; then
    echo "[BLOCKED] Invalid commit format: \"${commit_msg}\"" >&2
    echo "Required: <type>: <description> (feat/fix/refactor/docs/test/chore/perf/ci/release)" >&2
    exit 2
fi

# --- 2. Issue reference (skip chore/docs/ci/release/merge) ---
if ! echo "$commit_msg" | grep -qEi "^(chore|docs|ci|release|Merge|initial)"; then
    if ! echo "$cmd" | grep -qE '#[0-9]+'; then
        echo "[BLOCKED] Issue reference (#XX) required in commit message" >&2
        echo "Exempt types: chore, docs, ci, release" >&2
        exit 2
    fi
fi

# --- 3. Zero-tolerance pre-commit (lint/type/format checks) ---
project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$project_root" ]; then
    STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")

    # v1 frontend
    if echo "$STAGED" | grep -q "^frontend/" && [ -f "$project_root/frontend/package.json" ]; then
        if ! (cd "$project_root/frontend" && pnpm lint > /dev/null 2>&1); then
            echo "[BLOCKED] Frontend lint errors. Run: cd frontend && pnpm lint --fix" >&2
            exit 2
        fi
    fi

    # v1 backend
    if echo "$STAGED" | grep -q "^backend/" && [ -f "$project_root/backend/pyproject.toml" ]; then
        if ! (cd "$project_root/backend" && ruff check . > /dev/null 2>&1); then
            echo "[BLOCKED] Backend ruff errors. Run: cd backend && ruff check --fix ." >&2
            exit 2
        fi
    fi

    # v2 llm-gateway (ruff check + ruff format)
    if echo "$STAGED" | grep -q "^services/llm-gateway/"; then
        LLM_DIR="$project_root/services/llm-gateway"
        if [ -d "$LLM_DIR" ]; then
            if ! (cd "$LLM_DIR" && ruff check . > /dev/null 2>&1); then
                echo "[BLOCKED] llm-gateway ruff check errors. Run: cd services/llm-gateway && ruff check --fix ." >&2
                exit 2
            fi
            if ! (cd "$LLM_DIR" && ruff format --check src/ tests/ > /dev/null 2>&1); then
                echo "[BLOCKED] llm-gateway ruff format errors. Run: cd services/llm-gateway && ruff format src/ tests/" >&2
                exit 2
            fi
        fi
    fi

    # v2 intelligence-worker (ruff check + ruff format)
    if echo "$STAGED" | grep -q "^services/intelligence-worker/"; then
        IW_DIR="$project_root/services/intelligence-worker"
        if [ -d "$IW_DIR" ]; then
            if ! (cd "$IW_DIR" && ruff check . > /dev/null 2>&1); then
                echo "[BLOCKED] intelligence-worker ruff check errors. Run: cd services/intelligence-worker && ruff check --fix ." >&2
                exit 2
            fi
            if ! (cd "$IW_DIR" && ruff format --check src/ tests/ > /dev/null 2>&1); then
                echo "[BLOCKED] intelligence-worker ruff format errors. Run: cd services/intelligence-worker && ruff format src/ tests/" >&2
                exit 2
            fi
        fi
    fi

    # v2 control-api (go vet)
    if echo "$STAGED" | grep -q "^services/control-api/.*\.go$"; then
        GO_DIR="$project_root/services/control-api"
        if [ -d "$GO_DIR" ]; then
            if ! (cd "$GO_DIR" && go vet ./... > /dev/null 2>&1); then
                echo "[BLOCKED] control-api go vet errors. Run: cd services/control-api && go vet ./..." >&2
                exit 2
            fi
        fi
    fi
fi

echo "$input"
