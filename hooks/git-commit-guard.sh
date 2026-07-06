#!/bin/bash
# git-commit-guard.sh — Consolidated PreToolUse hook for git commit
# Combines: enforce-commit-format + enforce-issue-reference-on-commit + enforce-zero-tolerance-precommit
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Cheap pre-filter: skip non-git commands entirely.
case "$cmd" in *"git "*) ;; *) exit 0;; esac

# --- Resolve git context dir: honor `cd <dir> && ...` and `git -C <dir>` ---
# The hook process cwd is the SESSION cwd, not the repo the command targets.
# Without this, `cd ~/Developer/repo && git commit ...` issued from a non-repo
# cwd makes `git branch --show-current` return "" → false "detached HEAD"
# block, and the staged-file lint checks silently evaluate the wrong repo.
ctx_dir=$(CMD="$cmd" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
q1, q2 = chr(34), chr(39)
pat_val = r'((?:%s[^%s]+%s)|(?:%s[^%s]+%s)|(?:[^\s;&|]+))' % (q1, q1, q1, q2, q2, q2)
def _resolve(m):
    if not m:
        return ""
    d = os.path.expanduser(os.path.expandvars(m.group(1).strip(q1 + q2)))
    return d if d and os.path.isdir(d) else ""

# `git -C <dir>` wins over a leading `cd <dir> &&` (git resolves -C itself),
# but only when its value is a real directory — a `git -C` appearing inside a
# quoted string (e.g. an issue title) must not shadow a valid leading cd.
d = _resolve(re.search(r'git\s+-C\s+' + pat_val, cmd))
if not d:
    d = _resolve(re.match(r'^\s*cd\s+' + pat_val + r'\s*(?:&&|;)', cmd))
print(d)
PY
)
git_ctx() {
    if [[ -n "$ctx_dir" ]]; then git -C "$ctx_dir" "$@"; else git "$@"; fi
}

# cmd_norm: collapse git global options (-C <dir>, -c <k=v>, --no-pager) so the
# commit pattern matches below cannot be dodged with `git -C <repo> commit`
# (fail-open bypass). Quote-aware: -C "/path with spaces" collapses too.
# ctx_dir above still reads the ORIGINAL command.
cmd_norm=$(CMD="$cmd" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
q1, q2 = chr(34), chr(39)
val = r'(?:%s[^%s]*%s|%s[^%s]*%s|[^\s;&|]+)' % (q1, q1, q1, q2, q2, q2)
opt = r'(?:\s+-C\s+' + val + r'|\s+-c\s+' + val + r'|\s+--no-pager)'
print(re.sub(r'git' + opt + r'+(\s+)', r'git\g<1>', cmd), end="")
PY
)

# Gate: run on any git commit that carries a message source (-m/--message/-F/--file).
# -F/--file included so file-based messages are validated too (was unreachable before).
# -F has no \b so the attached form (-F<file>) is gated too.
if ! echo "$cmd_norm" | grep -qE 'git\s+commit\b.*(-m|--message|-F|--file\b)'; then
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
    _remote_url=$(git_ctx remote get-url origin 2>/dev/null || echo "")
    if [[ "$_remote_url" != *"/claude-code-skills"* ]]; then
        current_branch=$(git_ctx branch --show-current 2>/dev/null || echo "")
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
commit_msg=$(CMD="$cmd_norm" CTX_DIR="$ctx_dir" python3 - <<'PY'
import os
import re
import shlex
import sys

cmd = os.environ.get("CMD", "")

def heredoc_message(raw: str) -> str:
    # Only treat a heredoc as the commit message when it feeds git commit
    # (-m "$(cat <<EOF ...)" / -F - <<EOF). An unrelated heredoc elsewhere in
    # the command (e.g. writing a file that merely mentions git commit) must
    # not be validated as the commit subject.
    match = re.search(
        r"git\s+commit[^\n]*(?:\$\(\s*cat\s*|-F\s*-\s*|--file[= ]-\s*)"
        r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?",
        raw,
    )
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
        # -F <path> / -F<path> / --file <path> / --file=<path>: read message
        # from file. Relative paths resolve against CTX_DIR (the repo the
        # command targets via cd/-C), not the hook cwd. "-" (stdin) is
        # skipped; unreadable files are ignored (fail-open, same as the
        # existing behavior for empty messages).
        file_path = None
        if token in {"-F", "--file"} and j + 1 < len(tokens):
            file_path = tokens[j + 1]
            j += 2
        elif token.startswith("--file="):
            file_path = token.split("=", 1)[1]
            j += 1
        elif token.startswith("-F") and len(token) > 2 and not token.startswith("--file"):
            file_path = token[2:]
            j += 1
        if file_path is not None:
            if file_path != "-":
                ctx = os.environ.get("CTX_DIR", "")
                if ctx and not os.path.isabs(file_path):
                    file_path = os.path.join(ctx, file_path)
                try:
                    with open(os.path.expanduser(file_path)) as fh:
                        messages.append(fh.read())
                except OSError:
                    pass
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
project_root=$(git_ctx rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$project_root" ]; then
    STAGED=$(git_ctx diff --cached --name-only 2>/dev/null || echo "")

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
