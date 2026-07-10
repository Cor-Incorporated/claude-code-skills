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
# Primary count source: current transcript_path (session-local)
# Rule ref: delegation.md > テスト作成は原則Codex委任
# ========================================================================

set -euo pipefail

# --- Capture stdin (hook input JSON) EARLY so the subagent exemption can read agent_id ---
INPUT_JSON=""
if [[ ! -t 0 ]]; then
  INPUT_JSON=$(cat)
fi

# --- Subagent exemption ---
# Subagents ARE the delegated work and must not be blocked. CLAUDE_AGENT_DEPTH may
# NOT propagate to the hook subprocess, so we ALSO honor the stdin JSON .agent_id
# field (official Claude Code hook spec). Mirrors git-commit-guard.sh.
_is_subagent="false"
if [[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] || [[ -n "${CLAUDE_AGENT_ID:-}" ]]; then
  _is_subagent="true"
fi
if command -v jq &>/dev/null && [[ -n "${INPUT_JSON:-}" ]]; then
  _aid=$(printf '%s' "$INPUT_JSON" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
  [[ -n "$_aid" ]] && _is_subagent="true"
fi
[[ "$_is_subagent" == "true" ]] && exit 0

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/context-budget.json"

mkdir -p "$STATE_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" << 'EOF'
{
  "session_id": "",
  "mode": "auto",
  "contexts": {},
  "read_files": [],
  "read_count": 0,
  "write_test_doc_count": 0,
  "agent_count": 0,
  "warnings_issued": [],
  "started_at": ""
}
EOF
fi

# (stdin already captured into $INPUT_JSON at the top of this script)

FILE_PATH=""
TRANSCRIPT_PATH=""
SESSION_ID=""
HOOK_CWD=""
if [[ -n "$INPUT_JSON" ]]; then
  PARSED=$(echo "$INPUT_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    fp = data.get('tool_input', {}).get('file_path', '')
    print(fp)
    print(data.get('transcript_path', ''))
    print(data.get('session_id', ''))
    print(data.get('cwd', ''))
except Exception:
    print('')
    print('')
    print('')
    print('')
" 2>/dev/null || echo "")
  FILE_PATH=$(printf '%s\n' "$PARSED" | sed -n '1p')
  TRANSCRIPT_PATH=$(printf '%s\n' "$PARSED" | sed -n '2p')
  SESSION_ID=$(printf '%s\n' "$PARSED" | sed -n '3p')
  HOOK_CWD=$(printf '%s\n' "$PARSED" | sed -n '4p')
fi

# --- Planning mode exemption ---
MODE=$(_STATE="$STATE_FILE" python3 -c "
import json, os
with open(os.environ['_STATE']) as f:
    print(json.load(f).get('mode', 'auto'))
" 2>/dev/null || echo "auto")

if [[ "$MODE" == "planning" ]] || [[ "$MODE" == "research" ]]; then
  exit 0
fi

# Skip non-project files (hooks, memory, settings, state, tmp)
if [[ "$FILE_PATH" == *"/.claude/"* ]] || [[ "$FILE_PATH" == *"/memory/"* ]] || [[ "$FILE_PATH" == /tmp/* ]]; then
  exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

[[ ! -f "$STATE_FILE" ]] && echo '{}' > "$STATE_FILE"
_STATE_FILE="$STATE_FILE" _FILE_PATH="$FILE_PATH" _NOW="$NOW" _TRANSCRIPT_PATH="$TRANSCRIPT_PATH" _SESSION_ID="$SESSION_ID" _HOOK_CWD="$HOOK_CWD" python3 << 'PYEOF'
import hashlib
import json
import os
import re
import sys
import fcntl

state_file = os.environ['_STATE_FILE']
file_path = os.environ['_FILE_PATH']
now = os.environ['_NOW']
basename = os.path.basename(file_path)
transcript_path = os.environ.get('_TRANSCRIPT_PATH', '')
session_id = os.environ.get('_SESSION_ID', '')
hook_cwd = os.environ.get('_HOOK_CWD', '')

def classify(path):
    if not path:
        return False, False
    is_test_file = bool(re.search(r'(test_|\.test\.|\.spec\.|__tests__|_test\.)', path, re.IGNORECASE))
    is_doc_file = bool(re.search(r'(\.md$|/docs/|README|CHANGELOG|\.rst$)', path, re.IGNORECASE))
    if re.search(r'(CLAUDE\.md|Plans\.md|MEMORY\.md|AGENTS\.md)', path):
        is_doc_file = False
    return is_test_file, is_doc_file

is_test, is_doc = classify(file_path)
if not is_test and not is_doc:
    sys.exit(0)

def iter_tool_uses(record):
    message = record.get("message", {})
    content = message.get("content", [])
    if isinstance(content, dict):
        content = [content]
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield block.get("name", ""), block.get("input", {}) or {}

    # Lightweight fallback for synthetic transcripts and future format changes.
    tool_name = record.get("tool_name", "")
    tool_input = record.get("tool_input", {})
    if tool_name:
        yield tool_name, tool_input if isinstance(tool_input, dict) else {}

def count_from_transcript(transcript_path):
    if not transcript_path or not os.path.isfile(transcript_path):
        return None

    files = []
    try:
        with open(transcript_path, encoding="utf-8") as transcript:
            for line in transcript:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for name, tool_input in iter_tool_uses(record):
                    if name != "Write":
                        continue
                    prior_path = tool_input.get("file_path", "")
                    prior_is_test, prior_is_doc = classify(prior_path)
                    if prior_is_test or prior_is_doc:
                        files.append(prior_path)
    except OSError:
        return None

    unique = []
    seen = set()
    for prior_path in files:
        if prior_path and prior_path not in seen:
            unique.append(prior_path)
            seen.add(prior_path)
    if file_path and file_path not in seen:
        unique.append(file_path)
    return len(unique)

def fallback_context_key():
    raw = (
        session_id
        or transcript_path
        or hook_cwd
        or os.environ.get("CLAUDE_PROJECT_DIR", "")
        or os.getcwd()
    )
    return hashlib.sha256(raw.encode("utf-8", "ignore")).hexdigest()[:16]

def count_from_context_state():
    key = fallback_context_key()
    with open(state_file, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            state = json.load(f)
        except json.JSONDecodeError:
            state = {}

        if not state.get("started_at"):
            state["started_at"] = now
        contexts = state.setdefault("contexts", {})
        context = contexts.setdefault(key, {})
        files = context.setdefault("write_test_doc_files", [])
        if file_path and file_path not in files:
            files.append(file_path)
        context["write_test_doc_count"] = len(files)
        context["updated_at"] = now

        f.seek(0)
        f.truncate()
        json.dump(state, f, indent=2)
        fcntl.flock(f, fcntl.LOCK_UN)
    return len(files)

transcript_count = count_from_transcript(transcript_path)
count = transcript_count if transcript_count is not None else count_from_context_state()

file_type = "テスト" if is_test else "ドキュメント"

if count == 1:
    print(f"⚠️ [Context Budget Gate] {file_type}ファイル作成を検出: {basename}", file=sys.stderr)
    print(f"  → delegation.md ルール: {file_type}作成は原則 Codex CLI 経路C に委任してください。", file=sys.stderr)
    if is_test:
        print("  → 例外: TDD Red-Greenサイクル中、1ファイル10行未満、対話的判断が必要な場合", file=sys.stderr)
    print("  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"プロンプト\"", file=sys.stderr)
    # 1件目は警告のみ、続行許可
    sys.exit(0)
elif count >= 2:
    print(f"🚫 [Context Budget Gate] {file_type}ファイル{count}件目の作成をブロックしました。", file=sys.stderr)
    print(f"  → delegation.md ルール: 2件以上の{file_type}/ドキュメント作成は Codex CLI 経路C に委任必須。", file=sys.stderr)
    print("  → bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> \"プロンプト\"", file=sys.stderr)
    print("  → 例外事由がある場合: mode=planning に設定してください", file=sys.stderr)
    print("    bash ~/.claude/hooks/context-budget-set-mode.sh planning", file=sys.stderr)
    # 2件目以降はブロック（exit 2 = block per official spec）
    sys.exit(2)

PYEOF

# Hook exit code is determined by Python script above
# exit 0 = allow, exit 2 = block (official spec)
exit $?
