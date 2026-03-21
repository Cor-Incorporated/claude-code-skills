#!/usr/bin/env bash
# context-budget-write-gate.sh
# ========================================================================
# PreToolUse hook: Detects new test/doc file creation.
# Per delegation.md, test/doc file creation should be delegated to Codex CLI.
#
# Exemptions (2026-03-11):
#   - Subagent context (already delegated work)
#   - Planning/research mode
#
# Trigger: Before Write tool use
# State file: ~/.claude/state/context-budget.json
# Rule ref: delegation.md > テスト作成は原則Codex委任
# ========================================================================

set -euo pipefail

# --- Subagent exemption ---
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  exit 0
fi

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/context-budget.json"

mkdir -p "$STATE_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" << 'EOF'
{
  "session_id": "",
  "mode": "auto",
  "read_files": [],
  "read_count": 0,
  "write_test_doc_count": 0,
  "agent_count": 0,
  "warnings_issued": [],
  "started_at": ""
}
EOF
fi

# --- Planning mode exemption ---
MODE=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    print(json.load(f).get('mode', 'auto'))
" 2>/dev/null || echo "auto")

if [[ "$MODE" == "planning" ]] || [[ "$MODE" == "research" ]]; then
  exit 0
fi

INPUT_JSON=""
if [[ ! -t 0 ]]; then
  INPUT_JSON=$(cat)
fi

FILE_PATH=""
if [[ -n "$INPUT_JSON" ]]; then
  FILE_PATH=$(echo "$INPUT_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    fp = data.get('tool_input', {}).get('file_path', '')
    print(fp)
except:
    print('')
" 2>/dev/null || echo "")
fi

# Skip non-project files (hooks, memory, settings, state, tmp)
if [[ "$FILE_PATH" == *"/.claude/"* ]] || [[ "$FILE_PATH" == *"/memory/"* ]] || [[ "$FILE_PATH" == /tmp/* ]]; then
  exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 << PYEOF
import json, sys, os, re

state_file = "$STATE_FILE"
file_path = """$FILE_PATH"""
now = "$NOW"
basename = os.path.basename(file_path)

# Detect test file patterns
is_test = bool(re.search(r'(test_|\.test\.|\.spec\.|__tests__|_test\.)', file_path, re.IGNORECASE))

# Detect documentation file patterns
is_doc = bool(re.search(r'(\.md$|/docs/|README|CHANGELOG|\.rst$)', file_path, re.IGNORECASE))
# Exclude project config docs that are typically small edits
if re.search(r'(CLAUDE\.md|Plans\.md|MEMORY\.md|AGENTS\.md)', file_path):
    is_doc = False

if not is_test and not is_doc:
    sys.exit(0)

with open(state_file) as f:
    state = json.load(f)

if not state.get("started_at"):
    state["started_at"] = now

state["write_test_doc_count"] = state.get("write_test_doc_count", 0) + 1
count = state["write_test_doc_count"]

with open(state_file, "w") as f:
    json.dump(state, f, indent=2)

file_type = "テスト" if is_test else "ドキュメント"

if count == 1:
    print(f"⚠️ [Context Budget Gate] {file_type}ファイル作成を検出: {basename}")
    print(f"  → delegation.md ルール: {file_type}作成は原則 Codex CLI 経路C に委任してください。")
    if is_test:
        print("  → 例外: TDD Red-Greenサイクル中、1ファイル10行未満、対話的判断が必要な場合")
    print("  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"プロンプト\"")
    # 1件目は警告のみ、続行許可
    sys.exit(0)
elif count >= 2:
    print(f"🚫 [Context Budget Gate] {file_type}ファイル{count}件目の作成をブロックしました。")
    print(f"  → delegation.md ルール: 2件以上の{file_type}/ドキュメント作成は Codex CLI 経路C に委任必須。")
    print("  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"プロンプト\"")
    print("  → 例外事由がある場合: mode=planning に設定してください")
    print("    bash ~/.claude/hooks/context-budget-set-mode.sh planning")
    # 2件目以降はブロック（exit 1）
    sys.exit(1)

PYEOF

# Hook exit code is determined by Python script above
# If Python exits 0, hook allows; if Python exits 1, hook blocks
exit $?
