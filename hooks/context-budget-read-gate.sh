#!/usr/bin/env bash
# context-budget-read-gate.sh
# ========================================================================
# PreToolUse hook: Tracks file read count per session.
# At 3+ unique SOURCE CODE file reads, outputs a warning.
# At 4+ reads, outputs a BLOCK warning (strong recommendation).
#
# Exemptions (2026-03-11):
#   - Subagent context (CLAUDE_AGENT_DEPTH >= 1)
#   - Planning/research mode (state file flag)
#   - Non-source files (docs, config, tmp, agent output)
#   - .claude/, CLAUDE.md, MEMORY.md, node_modules/
#
# Trigger: Before Read tool use
# State file: ~/.claude/state/context-budget.json
# Rule ref: delegation.md > コンテキスト予算ゲート
# ========================================================================

set -euo pipefail

# --- Subagent exemption ---
# Agent tool spawns subprocesses with depth tracking.
# Subagents should NOT be warned to delegate to Codex — they ARE the delegated work.
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  exit 0
fi

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/context-budget.json"

mkdir -p "$STATE_DIR"

# Initialize state if missing
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
# If mode is "planning" or "research", all reads are exempt.
MODE=$(_STATE="$STATE_FILE" python3 -c "
import json, os
with open(os.environ['_STATE']) as f:
    print(json.load(f).get('mode', 'auto'))
" 2>/dev/null || echo "auto")

if [[ "$MODE" == "planning" ]] || [[ "$MODE" == "research" ]]; then
  exit 0
fi

# Get the file being read from tool_input (passed via stdin in hook context)
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

# --- Path-based exemptions ---
# Config, memory, hooks, settings
if [[ "$FILE_PATH" == *"/.claude/"* ]] || [[ "$FILE_PATH" == *"/memory/"* ]] || [[ "$FILE_PATH" == *"CLAUDE.md"* ]] || [[ "$FILE_PATH" == *"MEMORY.md"* ]]; then
  exit 0
fi

# node_modules, lock files
if [[ "$FILE_PATH" == *"node_modules/"* ]] || [[ "$FILE_PATH" == *"package-lock.json"* ]] || [[ "$FILE_PATH" == *"pnpm-lock.yaml"* ]] || [[ "$FILE_PATH" == *"yarn.lock"* ]]; then
  exit 0
fi

# Temp files, agent output, codex results
if [[ "$FILE_PATH" == /tmp/* ]] || [[ "$FILE_PATH" == *"codex-result"* ]] || [[ "$FILE_PATH" == *"codex-review"* ]]; then
  exit 0
fi

# Documentation / architecture / config files (research reads, not implementation)
if [[ "$FILE_PATH" == *"/docs/"* ]] || [[ "$FILE_PATH" == *".md" ]] || [[ "$FILE_PATH" == *".yml" ]] || [[ "$FILE_PATH" == *".yaml" ]] || [[ "$FILE_PATH" == *".toml" ]] || [[ "$FILE_PATH" == *".json" && "$FILE_PATH" != *".test."* ]]; then
  exit 0
fi

# Plans.md, AGENTS.md, and similar planning files
if [[ "$FILE_PATH" == *"Plans.md"* ]] || [[ "$FILE_PATH" == *"AGENTS.md"* ]]; then
  exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Update state and check thresholds — only for SOURCE CODE reads
[[ ! -f "$STATE_FILE" ]] && echo '{}' > "$STATE_FILE"
_STATE="$STATE_FILE" _FILE="$FILE_PATH" _NOW="$NOW" python3 << PYEOF
import json, sys, os, re, fcntl

state_file = os.environ['_STATE']
file_path = os.environ['_FILE']
now = os.environ['_NOW']

# Only track source code files
source_exts = {'.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs', '.swift', '.kt', '.java', '.rb', '.php', '.vue', '.svelte', '.css', '.scss', '.sql', '.prisma', '.graphql'}
ext = os.path.splitext(file_path)[1].lower()
if ext not in source_exts:
    sys.exit(0)

with open(state_file, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    state = json.load(f)

    if not state.get("started_at"):
        state["started_at"] = now

    # Track unique file reads only
    if file_path and file_path not in state.get("read_files", []):
        state.setdefault("read_files", []).append(file_path)
        state["read_count"] = len(state["read_files"])

    count = state.get("read_count", 0)

    f.seek(0)
    f.truncate()
    json.dump(state, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)

# Threshold warnings
if count == 3:
    print("⚠️ [Context Budget Gate] ソースコード3ファイル読み込み到達。Codex CLI 経路C への委任を検討してください。", file=sys.stderr)
    print("  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"<prompt>\"", file=sys.stderr)
    print("  → 計画・調査中なら mode=planning に設定（bash ~/.claude/hooks/context-budget-set-mode.sh planning）", file=sys.stderr)
elif count >= 4:
    print("🚫 [BLOCK] ソースコード{}ファイル読み込み。強制停止。Codex CLI 経路C に委任してください。".format(count), file=sys.stderr)
    print("  → 対話的判断が必要な場合のみ mode=planning に変更可", file=sys.stderr)
    sys.exit(2)

PYEOF

# Hook exit code is determined by Python script above
exit $?
