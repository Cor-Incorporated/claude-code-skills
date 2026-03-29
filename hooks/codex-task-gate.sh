#!/bin/bash
# codex-task-gate.sh — PreToolUse hook for Write/Edit AND Bash(codex-*)
# 1. Detects test/doc file creation that should be delegated to Codex CLI.
# 2. Enforces single consolidated Codex delegation (no split calls).
# Enforces the delegation policy: large test suites and docs → Codex.
set -euo pipefail

input=$(cat)

ensure_json_file() {
    local state_file="$1"
    [[ -f "$state_file" ]] || echo '{}' > "$state_file"
}

reserve_codex_call() {
    local budget_file="$1"
    ensure_json_file "$budget_file"

    _BUDGET_FILE="$budget_file" python3 -c '
import json, os, fcntl, sys
f_path = os.environ["_BUDGET_FILE"]
with open(f_path, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    try:
        count = int(s.get("codex_call_count", 0))
        if count >= 1:
            print(count)
            sys.exit(1)
        s["codex_call_count"] = count + 1
        f.seek(0)
        f.truncate()
        json.dump(s, f, indent=2)
        print(count + 1)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
' 2>/dev/null
}

increment_json_counter() {
    local state_file="$1"
    local counter_key="$2"
    ensure_json_file "$state_file"

    _STATE_FILE="$state_file" _COUNTER_KEY="$counter_key" python3 -c '
import json, os, fcntl
f_path = os.environ["_STATE_FILE"]
counter_key = os.environ["_COUNTER_KEY"]
with open(f_path, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        s = json.load(f)
    except json.JSONDecodeError:
        s = {}
    try:
        new_count = int(s.get(counter_key, 0)) + 1
        s[counter_key] = new_count
        f.seek(0)
        f.truncate()
        json.dump(s, f, indent=2)
        print(new_count)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
' 2>/dev/null
}

# --- Rule: Codex batch enforcement (for Bash tool) ---
# Detect codex-parallel.sh / codex exec calls and block 2nd+ call
tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
bash_cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only match actual EXECUTION of Codex commands, not mentions in cat/grep/echo/ls
# - bash <path>codex-parallel.sh or codex-orchestrate.sh
# - codex exec at command start position (with optional env var prefixes)
first_line=$(echo "$bash_cmd" | head -1)
is_codex_exec=false
if echo "$first_line" | grep -qE '^\s*(\S+=\S+\s+)*bash\s+\S*codex-(parallel|orchestrate)'; then
    is_codex_exec=true
elif echo "$first_line" | grep -qE '^\s*(\S+=\S+\s+)*codex\s+exec\b'; then
    # 経路A (codex exec review) はレビュー専用 — バジェットカウント対象外
    # 経路C (codex exec <implementation>) のみカウントする
    if ! echo "$first_line" | grep -qE 'codex\s+exec\s+review\b'; then
        is_codex_exec=true
    fi
fi

if [[ "$tool_name" == "Bash" ]] && [[ "$is_codex_exec" == "true" ]]; then
    BUDGET_FILE="${HOME}/.claude/state/context-budget.json"
    mkdir -p "$(dirname "$BUDGET_FILE")"
    if ! reserve_codex_call "$BUDGET_FILE" >/dev/null; then
        echo "🚫 [Codex Batch Required] 2回目のCodex呼び出しをブロック。" >&2
        echo "" >&2
        echo "ルール: Codexには1つの統合タスクとして委任してください。" >&2
        echo "  → 複数小分けではなく、1プロンプトにまとめる" >&2
        echo "  → Codex内部サブエージェントが分割を担当" >&2
        echo "  → codex-orchestrate.sh + tasks.json で一括委任" >&2
        exit 2
    fi
    exit 0
fi

file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

[ -z "$file_path" ] && exit 0

# Skip .claude/ config files, CLAUDE.md, MEMORY.md
if echo "$file_path" | grep -qE '(/\.claude/|CLAUDE\.md|MEMORY\.md|node_modules/|package-lock)'; then
    exit 0
fi

# State file for tracking
STATE_FILE="${HOME}/.claude/state/codex-task-gate.json"
mkdir -p "$(dirname "$STATE_FILE")"
ensure_json_file "$STATE_FILE"

# Detect test file creation
is_test=false
if echo "$file_path" | grep -qE '(_test\.(go|py|ts|tsx|js)|\.test\.(ts|tsx|js)|\.spec\.(ts|tsx|js)|test_[a-z])'; then
    is_test=true
fi

# Detect doc file creation
is_doc=false
if echo "$file_path" | grep -qE '\.(md|rst|txt)$' && echo "$file_path" | grep -qiE '(docs?/|readme|changelog|guide)'; then
    is_doc=true
fi

if [ "$is_test" = true ]; then
    new_count=$(increment_json_counter "$STATE_FILE" "test_files_created")

    if [ "$new_count" -ge 3 ]; then
        echo "" >&2
        echo "⚠️  [CODEX DELEGATION RECOMMENDED]" >&2
        echo "You have created/modified ${new_count} test files in this session." >&2
        echo "" >&2
        echo "Per delegation rules, bulk test creation should go to Codex CLI:" >&2
        echo "  bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> '<prompt>'" >&2
        echo "" >&2
        echo "Codex handles test creation autonomously with internal sub-agents." >&2
        echo "Pass ONE large task — Codex will split it internally." >&2
        echo "" >&2
        echo "Continue if: TDD red-green cycle, interactive design, or <10 lines." >&2
        echo "" >&2
    fi
fi

if [ "$is_doc" = true ]; then
    new_count=$(increment_json_counter "$STATE_FILE" "doc_files_created")

    if [ "$new_count" -ge 2 ]; then
        echo "" >&2
        echo "⚠️  [CODEX DELEGATION RECOMMENDED]" >&2
        echo "You have created/modified ${new_count} doc files in this session." >&2
        echo "Bulk documentation updates should go to Codex CLI (経路C)." >&2
        echo "" >&2
    fi
fi

exit 0
