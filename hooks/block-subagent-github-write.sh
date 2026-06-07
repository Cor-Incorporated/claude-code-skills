#!/usr/bin/env bash
# block-subagent-github-write.sh — Prevent ask-gated git/GitHub writes in subagents
# =========================================================================
# Subagents/team workers cannot satisfy interactive "ask" permission prompts.
# If they attempt push/PR creation/merge, they stall or fail without giving the
# parent agent a clean execution path. Block these commands early with an
# actionable message so the parent agent performs the final publish step.
# =========================================================================

set -euo pipefail

input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi
command -v jq &>/dev/null || exit 0

json_agent_id=""
if [[ -n "$input" ]]; then
  json_agent_id=$(echo "$input" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
fi

if [[ "${CLAUDE_AGENT_DEPTH:-0}" -lt 1 ]] \
   && [[ -z "${CLAUDE_AGENT_ID:-}" ]] \
   && [[ -z "$json_agent_id" ]]; then
  exit 0
fi

[[ -z "$input" ]] && exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[[ "$tool_name" == "Bash" ]] || exit 0

cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[[ -z "$cmd" ]] && exit 0

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

first_line=$(echo "$cmd" | head -1 | xargs 2>/dev/null || echo "$cmd")

if ! echo "$first_line" | grep -qE '^(git\s+push\b|gh\s+pr\s+(create|merge|ready|edit)\b|gh\s+issue\s+(create|comment|edit|close)\b)'; then
  exit 0
fi

echo "🚫 [BLOCK] サブエージェント/Team worker から ask 権限が必要な Git/GitHub 書き込みは実行できません。" >&2
echo "" >&2
echo "  検出コマンド: $first_line" >&2
echo "" >&2
echo "  理由:" >&2
echo "  - worker は対話的 permission ask を承認できません" >&2
echo "  - git push / gh pr create は親エージェントで実行する必要があります" >&2
echo "" >&2
echo "  対応:" >&2
echo "  1. worker には本文作成・検証・差分準備だけを任せる" >&2
echo "  2. 親エージェントが git push / gh pr create / gh pr merge を実行する" >&2
echo "  3. read-only 確認は worker で継続可 (gh pr view/list, git status, git diff)" >&2
exit 2
