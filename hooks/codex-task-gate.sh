#!/bin/bash
# codex-task-gate.sh — PreToolUse hook for Write/Edit AND Bash(codex-*)
# 1. Detects test/doc file creation that should be delegated to Codex CLI.
# 2. Enforces single consolidated Codex delegation (no split calls).
# Enforces the delegation policy: large test suites and docs → Codex.
set -euo pipefail

input=$(cat)

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
    is_codex_exec=true
fi

if [[ "$tool_name" == "Bash" ]] && [[ "$is_codex_exec" == "true" ]]; then
    BUDGET_FILE="${HOME}/.claude/state/context-budget.json"
    if [[ -f "$BUDGET_FILE" ]]; then
        codex_count=$(_BUDGET_FILE="$BUDGET_FILE" python3 -c "
import json, os
with open(os.environ['_BUDGET_FILE']) as f:
    print(json.load(f).get('codex_call_count', 0))
" 2>/dev/null || echo "0")
        if [[ "$codex_count" -ge 1 ]]; then
            echo "🚫 [Codex Batch Required] 2回目のCodex呼び出しをブロック。" >&2
            echo "" >&2
            echo "ルール: Codexには1つの統合タスクとして委任してください。" >&2
            echo "  → 複数小分けではなく、1プロンプトにまとめる" >&2
            echo "  → Codex内部サブエージェントが分割を担当" >&2
            echo "  → codex-orchestrate.sh + tasks.json で一括委任" >&2
            exit 2
        fi
        # Increment codex call count
        _BUDGET_FILE="$BUDGET_FILE" python3 -c "
import json, os
f = os.environ['_BUDGET_FILE']
with open(f) as fh:
    s = json.load(fh)
s['codex_call_count'] = s.get('codex_call_count', 0) + 1
with open(f, 'w') as fh:
    json.dump(s, fh, indent=2)
" 2>/dev/null
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
[ ! -f "$STATE_FILE" ] && echo '{"test_files_created":0,"doc_files_created":0}' > "$STATE_FILE"

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
    count=$(jq -r '.test_files_created // 0' "$STATE_FILE")
    new_count=$((count + 1))
    jq --argjson c "$new_count" '.test_files_created = $c' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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
    count=$(jq -r '.doc_files_created // 0' "$STATE_FILE")
    new_count=$((count + 1))
    jq --argjson c "$new_count" '.doc_files_created = $c' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    if [ "$new_count" -ge 2 ]; then
        echo "" >&2
        echo "⚠️  [CODEX DELEGATION RECOMMENDED]" >&2
        echo "You have created/modified ${new_count} doc files in this session." >&2
        echo "Bulk documentation updates should go to Codex CLI (経路C)." >&2
        echo "" >&2
    fi
fi

exit 0
