#!/usr/bin/env bash
# notify-agent-failure.sh — PostToolUseFailure hook for Agent
# =========================================================================
# When a subagent/worker fails, inject a concise failure summary back into the
# parent session and persist the latest failure metadata in ~/.claude/state.
# This makes hook exit-2 failures actionable instead of silently stalling.
# =========================================================================

set -uo pipefail

input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
[[ -z "$input" ]] && exit 0
command -v jq &>/dev/null || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[[ "$tool_name" == "Agent" ]] || exit 0

is_interrupt=$(echo "$input" | jq -r '.is_interrupt // false' 2>/dev/null || echo "false")
[[ "$is_interrupt" == "true" ]] && exit 0

subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
description=$(echo "$input" | jq -r '.tool_input.description // ""' 2>/dev/null || echo "")
team_name=$(echo "$input" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")
error_msg=$(echo "$input" | jq -r '.error // ""' 2>/dev/null || echo "")
[[ -z "$error_msg" ]] && exit 0

failure_stage="tool_execution"
next_step="親エージェントが失敗内容を確認して、必要なら同じ作業を直接実行してください。"

if echo "$error_msg" | grep -qiE 'permission|ask 権限|ask permission|Git/GitHub 書き込み|^\s*🚫 \[BLOCK\]'; then
  failure_stage="permission_gate"
  next_step="ask 権限が必要な git push / gh pr create / gh pr merge は親エージェントで実行してください。worker には本文作成・検証のみ委任します。"
elif echo "$error_msg" | grep -qiE 'context budget'; then
  failure_stage="context_budget"
  next_step="読み込み量を減らすか、探索を別 worker に分けて再実行してください。"
elif echo "$error_msg" | grep -qiE 'three-way merge|patch does not apply|merge_back'; then
  failure_stage="merge_back"
  next_step="生成状態や作業ツリー競合を除去してから再試行してください。"
elif echo "$error_msg" | grep -qiE '\baborted\b'; then
  failure_stage="aborted"
  next_step="直前の hook/permission ブロックを確認し、失敗理由を解消してから再実行してください。"
fi

summary=$(python3 - <<'PY' "$subagent_type" "$description" "$team_name" "$failure_stage" "$error_msg" "$next_step"
import json, sys
subagent_type, description, team_name, failure_stage, error_msg, next_step = sys.argv[1:]
error_line = next((line.strip() for line in error_msg.splitlines() if line.strip()), "").strip()
payload = {
    "subagent_type": subagent_type or "unknown",
    "description": description,
    "team_name": team_name,
    "failure_stage": failure_stage,
    "error": error_line[:400],
    "next_step": next_step,
}
print(json.dumps(payload, ensure_ascii=False))
PY
)

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/agent-failure-last.json"
mkdir -p "$STATE_DIR"
printf '%s\n' "$summary" > "$STATE_FILE"

context=$(python3 - <<'PY' "$summary"
import json, sys
payload = json.loads(sys.argv[1])
label = payload["subagent_type"]
desc = payload.get("description") or ""
team = payload.get("team_name") or ""
who = label
if desc:
    who += f" / {desc}"
if team:
    who += f" / team={team}"
msg = (
    f"[agent-failure] {who} が失敗しました。\n"
    f"  stage: {payload['failure_stage']}\n"
    f"  error: {payload['error']}\n"
    f"  next: {payload['next_step']}"
)
print(msg)
PY
)

jq -n --arg ctx "$context" '{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUseFailure",
    "additionalContext": $ctx
  }
}'
