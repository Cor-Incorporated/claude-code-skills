#!/bin/bash
# git-commit-guard.sh — Consolidated PreToolUse hook for git commit
# Combines: enforce-commit-format + enforce-issue-reference-on-commit + enforce-zero-tolerance-precommit
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

if ! echo "$cmd" | grep -qE 'git\s+commit\s+.*-m'; then
    exit 0
fi

# --- Rule 0: Block direct commits on non-base branches from main session ---
# WHITELIST approach: only base branches (develop, main, master) allowed for main agent.
# All other branches require delegation to subagent/TeamCreate.
# This prevents bypass via creative branch naming (e.g., update/, hotfix/, etc.)
# Ref: Issue #10 — AI self-bypass via branch rename (2026-03-22)
#
# Subagent detection: check BOTH env var AND JSON input for agent context.
# CLAUDE_AGENT_DEPTH may not propagate to hook processes, so also check
# agent_id in the stdin JSON (official Claude Code hook spec).
IS_SUBAGENT="false"
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
    IS_SUBAGENT="true"
fi
# Also check JSON input for agent_id (more reliable than env vars)
if command -v jq &>/dev/null && [[ -n "$input" ]]; then
    json_agent_id=$(echo "$input" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
    [[ -n "$json_agent_id" ]] && IS_SUBAGENT="true"
fi
if [[ "$IS_SUBAGENT" == "false" ]]; then
    # claude-code-skills repo exemption: this repo IS the hook infrastructure.
    # Blocking main agent commits causes circular dependencies when fixing hooks.
    _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$_remote_url" != *"/claude-code-skills"* ]]; then
        current_branch=$(git branch --show-current 2>/dev/null || echo "")
        # Whitelist: only base branches are allowed for main agent commits
        case "$current_branch" in
            develop|main|master) ;; # allowed base branches
            "")
                echo "🚫 [Claude Code hook: git-commit-guard.sh] Delegation Required" >&2
                echo "  detached HEAD 状態での commit は subagent に委任してください。" >&2
                echo "  NOTE: これは Claude Code 側の PreToolUse hook です（Cursor / pre-commit のリポジトリフックではありません）。" >&2
                echo "  Source: ~/.claude/hooks/git-commit-guard.sh / settings.json (PreToolUse: Bash)" >&2
                exit 2
                ;;
            *)
                # Relaxed (2026-05-30): main agent may commit directly on feature
                # branches. Review is enforced at PR create/merge, so commit-level
                # delegation (Issue #10) is redundant friction. Detached HEAD still
                # requires delegation; format/issue-ref/lint checks below still apply.
                ;;
        esac
    fi
fi

# --- Extract commit message ---
# Git allows multiple -m/--message flags and joins them as paragraphs. The
# guard must validate the first paragraph as the subject while still accepting
# issue references in later paragraphs.
commit_msg=$(CMD="$cmd" python3 - <<'PY'
import os
import re
import shlex
import sys

cmd = os.environ.get("CMD", "")

def heredoc_message(raw: str) -> str:
    match = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", raw)
    if not match:
        return ""
    marker = match.group(1)
    lines = raw.splitlines()
    for i, line in enumerate(lines):
        if "<<" in line and marker in line:
            body = []
            for candidate in lines[i + 1:]:
                if candidate.strip() == marker:
                    return "\n".join(body).strip()
                body.append(candidate)
            return ""
    return ""

message = heredoc_message(cmd)
if message:
    print(message)
    sys.exit(0)

try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    sys.exit(0)

messages = []
for i in range(len(tokens) - 1):
    if tokens[i:i + 2] != ["git", "commit"]:
        continue
    j = i + 2
    while j < len(tokens):
        token = tokens[j]
        if token in {"&&", "||", ";", "|"}:
            break
        if token in {"-m", "--message"} and j + 1 < len(tokens):
            messages.append(tokens[j + 1])
            j += 2
            continue
        if token.startswith("--message="):
            messages.append(token.split("=", 1)[1])
            j += 1
            continue
        if token.startswith("-m") and token != "-m":
            messages.append(token[2:])
            j += 1
            continue
        j += 1
    break

if messages:
    print("\n\n".join(messages))
PY
)

[ -z "$commit_msg" ] && exit 0
commit_msg=$(echo "$commit_msg" | sed 's/^[[:space:]]*//')
commit_subject=$(printf '%s\n' "$commit_msg" | sed -n '/[^[:space:]]/{p; q;}')

# --- 1. Conventional Commit format ---
VALID_TYPES="feat|fix|refactor|docs|test|chore|perf|ci|release"
if ! echo "$commit_subject" | grep -qE "^(${VALID_TYPES})(\\(.+\\))?: .+"; then
    echo "[BLOCKED] Invalid commit format: \"${commit_subject}\"" >&2
    echo "Required: <type>: <description> (feat/fix/refactor/docs/test/chore/perf/ci/release)" >&2
    exit 2
fi

# --- 2. Issue reference (skip chore/docs/ci/release/merge) ---
if ! echo "$commit_subject" | grep -qEi "^(chore|docs|ci|release|Merge|initial)"; then
    if ! echo "$commit_msg" | grep -qE '#[0-9]+'; then
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

exit 0
