#!/usr/bin/env bash
# context-budget-agent-gate.sh
# ========================================================================
# PreToolUse hook: Agent launch governance (main session only).
#
# Enforces 3 rules:
#   1. BLOCK isolation: "worktree" (stale develop base, 3/3 failed 2026-03-18)
#   2. BLOCK 2+ implementation agents → force TeamCreate with integrity checker
#   3. WARN at 3+ agents → suggest Codex orchestration for mechanical tasks
#
# Exemptions:
#   - Subagent context (CLAUDE_AGENT_DEPTH >= 1): not counted/blocked
#   - Research/review agents: not counted as implementation
#   - Planning/research mode
#
# Trigger: Before Agent tool use
# State file: ~/.claude/state/context-budget.json
# Rule ref: delegation.md, feedback_use_teamcreate_not_subagent.md
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
  "impl_agent_count": 0,
  "codex_call_count": 0,
  "warnings_issued": [],
  "started_at": ""
}
EOF
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

INPUT_JSON=""
if [[ ! -t 0 ]]; then
  INPUT_JSON=$(cat)
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Pass all dynamic values via environment variables (not string interpolation)
# to prevent shell injection via crafted JSON input
_STATE_FILE="$STATE_FILE" _NOW="$NOW" _INPUT_JSON="$INPUT_JSON" python3 << 'PYEOF'
import json, sys, os

state_file = os.environ["_STATE_FILE"]
now = os.environ["_NOW"]
input_json = os.environ.get("_INPUT_JSON", "")

RESEARCH_TYPES = {
    "Explore", "architect", "planner", "Plan",
    "code-reviewer", "security-reviewer", "feature-dev:code-reviewer",
    "feature-dev:code-explorer", "feature-dev:code-architect",
    "claude-code-guide", "general-purpose",
}

RESEARCH_KEYWORDS = [
    "調査", "確認", "check", "review", "explore", "research",
    "read", "verify", "分析", "検証", "compare",
]

with open(state_file) as f:
    state = json.load(f)

if not state.get("started_at"):
    state["started_at"] = now

# Parse Agent tool input
tool_input = {}
try:
    if input_json.strip():
        data = json.loads(input_json)
        ti = data.get("tool_input", {})
        tool_input = json.loads(ti) if isinstance(ti, str) else ti
except Exception:
    pass

# --- Rule 1: BLOCK worktree isolation ---
isolation = tool_input.get("isolation", "")
if isolation == "worktree":
    print('🚫 [Worktree Block] isolation: "worktree" は使用禁止です。')
    print("")
    print("理由: stale develop base問題で3回連続失敗 (2026-03-18)。")
    print("代替: TeamCreate / isolation なし Agent / 手動ブランチ作成")
    sys.exit(2)

# --- Classify agent type ---
subagent_type = tool_input.get("subagent_type", "")
description = tool_input.get("description", "").lower()
is_research = (
    subagent_type in RESEARCH_TYPES
    or any(kw in description for kw in RESEARCH_KEYWORDS)
)

# --- Rule 2: BLOCK 2+ standalone impl agents → TeamCreate ---
# TeamCreate workers (team_name set) are EXEMPT — that's the correct pattern
has_team = bool(tool_input.get("team_name", ""))
if not is_research and not has_team:
    impl_count = state.get("impl_agent_count", 0)
    if impl_count >= 1:
        print("🚫 [TeamCreate Required] 2つ目のスタンドアロン実装Agentをブロック。")
        print("")
        print("ルール: 並列実装 → TeamCreate (整合性チェックWorker含む)")
        print("  → worktree問題なし（共有コンテキスト）")
        print("  → ADR/プロダクト整合性を常時検証")
        print("")
        print("TeamCreate済みならteam_nameを指定してください。")
        print("単一タスクなら isolation なし Agent を使用してください。")
        with open(state_file, "w") as f:
            json.dump(state, f, indent=2)
        sys.exit(2)
    state["impl_agent_count"] = impl_count + 1

# --- Count total agents ---
state["agent_count"] = state.get("agent_count", 0) + 1
count = state["agent_count"]

with open(state_file, "w") as f:
    json.dump(state, f, indent=2)

# --- Rule 3: WARN at 3+ total agents ---
if count == 3:
    print("⚠️ [Context Budget] 3エージェント起動。")
    print("  → 機械的タスクは codex-orchestrate.sh / TeamCreate を検討")
elif count == 5:
    print("🚫 [Context Budget] 5エージェント。コンテキスト消費が深刻。")
    print("  → Codex CLI 経路C への切り替えを強く推奨")
elif count >= 7:
    print("🚫🚫 [Context Budget] {}エージェント（危険水域）。".format(count))
    print("  → 残タスクはCodexに委任してください")

PYEOF

exit 0
