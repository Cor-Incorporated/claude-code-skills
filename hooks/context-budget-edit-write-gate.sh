#!/usr/bin/env bash
# context-budget-edit-write-gate.sh
# ========================================================================
# PreToolUse hook (Edit/Write): Blocks code changes when too many source
# files have been read in the session. Parses session transcript to count
# unique source code Read calls.
#
# Design: Option B — since Read/Glob/Grep hooks don't fire in Claude Code
# v2.x, enforcement happens at the point of change (Edit/Write).
#
# Thresholds:
#   3 unique source files read → WARNING (stderr)
#   4+ unique source files read → BLOCK (exit 2, non-bypassable)
#
# Exemptions:
#   - Subagent context (CLAUDE_AGENT_DEPTH >= 1)
#   - Planning/research mode (state file flag)
#   - Files in .claude/, node_modules/, /tmp/, docs/, *.md, *.json, *.yml
#
# Trigger: PreToolUse on Edit and Write
# ========================================================================

set -euo pipefail

# --- Subagent exemption ---
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  exit 0
fi

# --- Read stdin (hook input JSON) ---
INPUT_JSON=""
if [[ ! -t 0 ]]; then
  INPUT_JSON=$(cat)
fi

if [[ -z "$INPUT_JSON" ]]; then
  exit 0
fi

# --- Extract transcript_path from hook input ---
TRANSCRIPT_PATH=$(echo "$INPUT_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# --- Planning mode exemption ---
STATE_FILE="$HOME/.claude/state/context-budget.json"
if [[ -f "$STATE_FILE" ]]; then
  MODE=$(_STATE="$STATE_FILE" python3 -c "
	import json, os
	with open(os.environ['_STATE']) as f:
	    print(json.load(f).get('mode', 'auto'))
	" 2>/dev/null || echo "auto")
  if [[ "$MODE" == "planning" ]] || [[ "$MODE" == "research" ]]; then
    exit 0
  fi
fi

# --- Extract file being edited ---
EDIT_FILE=$(echo "$INPUT_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('file_path', ''))
except:
    print('')
" 2>/dev/null || echo "")

# Exempt: editing non-source files (config, docs, hooks, etc.)
case "$EDIT_FILE" in
  */.claude/*|*CLAUDE.md*|*MEMORY.md*|*Plans.md*|*/node_modules/*|/tmp/*)
    exit 0 ;;
  *.md|*.yml|*.yaml|*.toml|*.json|*.txt|*.env*|*.gitignore|*.dockerignore)
    exit 0 ;;
esac

# --- Count unique source code Read calls from transcript ---
export TRANSCRIPT_PATH
RESULT=$(python3 << 'PYEOF'
import json, sys, os

transcript_path = os.environ.get("TRANSCRIPT_PATH", "")

source_exts = {'.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs', '.swift',
               '.kt', '.java', '.rb', '.php', '.vue', '.svelte', '.css',
               '.scss', '.sql', '.prisma', '.graphql'}

exempt_patterns = [
    '/.claude/', '/node_modules/', '/memory/', 'CLAUDE.md', 'MEMORY.md',
    'Plans.md', 'AGENTS.md', '/docs/', '/tmp/', 'codex-result', 'codex-review',
    'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock'
]

read_files = set()

try:
    with open(transcript_path) as f:
        for line in f:
            try:
                d = json.loads(line.strip())
                msg = d.get('message', {})
                content = msg.get('content', [])
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get('type') != 'tool_use':
                        continue
                    if block.get('name') != 'Read':
                        continue
                    fp = block.get('input', {}).get('file_path', '')
                    if not fp:
                        continue

                    # Check extension
                    ext = os.path.splitext(fp)[1].lower()
                    if ext not in source_exts:
                        continue

                    # Check exemptions
                    exempt = False
                    for pat in exempt_patterns:
                        if pat in fp:
                            exempt = True
                            break
                    if exempt:
                        continue

                    read_files.add(fp)
            except (json.JSONDecodeError, KeyError):
                continue
except Exception:
    pass

count = len(read_files)
# Output: count|file1|file2|...
files_str = '|'.join(sorted(read_files)[:10])
print(f"{count}|{files_str}")
PYEOF
) || true

if [[ -z "$RESULT" ]]; then
  RESULT="0|"
fi
COUNT=$(echo "$RESULT" | cut -d'|' -f1 | tr -d '[:space:]')
FILES=$(echo "$RESULT" | cut -d'|' -f2-)
if [[ -z "$COUNT" ]] || ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT=0
fi

# --- Enforce thresholds ---
if [[ "$COUNT" -ge 4 ]]; then
  echo "🚫 [CONTEXT BUDGET BLOCK] ソースコード${COUNT}ファイル読み込み済み。Edit/Write を拒否します。" >&2
  echo "  Codex CLI 経路C に委任してください:" >&2
  echo "  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"<prompt>\"" >&2
  echo "  読み込み済みファイル: ${FILES//|/, }" >&2
  echo "  例外: mode=planning に変更可（bash ~/.claude/hooks/context-budget-set-mode.sh planning）" >&2
  exit 2
elif [[ "$COUNT" -ge 3 ]]; then
  echo "⚠️ [CONTEXT BUDGET WARNING] ソースコード${COUNT}ファイル読み込み済み。次のEditでブロックされます。" >&2
  echo "  Codex CLI 経路C への委任を検討してください。" >&2
  echo "  読み込み済みファイル: ${FILES//|/, }" >&2
fi

exit 0
