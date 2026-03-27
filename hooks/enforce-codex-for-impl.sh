#!/bin/bash
# enforce-codex-for-impl.sh — PreToolUse hook (matcher: Agent)
# =========================================================================
# Issue #189: Warn when implementation tasks are delegated to sub-agents
# instead of Codex CLI route C (ADR-004)
#
# Ref: ADR-004 — "1タスク+長時間+自律+大規模 → Codex CLI経路C"
# Ref: delegation.md — 実装タスクはCodex CLI経路Cで委任
# Ref: https://docs.anthropic.com/en/docs/claude-code/hooks
#   Event: PreToolUse (matcher: Agent)
#   Exit 0 = allow (warning only, no block)
#
# Behavior:
#   - WARNING only (exit 0) — does not block the Agent call
#   - Triggers when subagent_type=general-purpose AND prompt contains
#     implementation keywords (実装/作成/Edit/Write/変更/implement/create/modify)
#   - Passes silently for specialized subagents (code-reviewer, Explore, etc.)
#   - Passes silently for investigation-only prompts (調査/検索/確認/レビュー)
#
# Judgment table (from Issue #189):
#   | Condition                                 | Action  |
#   |-------------------------------------------|---------|
#   | Prompt has investigation keywords only     | PASS    |
#   | Prompt has implementation keywords         | WARNING |
#   | subagent_type != general-purpose           | PASS    |
# =========================================================================

set -euo pipefail

# Read tool input from stdin
input=$(cat)

# Handle both object and stringified tool_input
tool_input=$(echo "$input" | jq -r '
  if (.tool_input | type) == "string" then .tool_input | fromjson
  else .tool_input // {}
  end
' 2>/dev/null || echo '{}')

subagent=$(echo "$tool_input" | jq -r '.subagent_type // "general-purpose"' 2>/dev/null || echo "general-purpose")
prompt=$(echo "$tool_input" | jq -r '.prompt // ""' 2>/dev/null || echo "")
description=$(echo "$tool_input" | jq -r '.description // ""' 2>/dev/null || echo "")

# --- Always allow specialized subagent types ---
case "$subagent" in
  code-reviewer|Explore|Plan|security-reviewer|build-error-resolver|e2e-runner|refactor-cleaner|tdd-guide|architect|planner|typescript-pro|python-pro|golang-pro|swift-expert|technical-writer|doc-updater|feature-dev:*)
    exit 0
    ;;
esac

# --- Only inspect general-purpose subagents ---
if [[ "$subagent" != "general-purpose" ]]; then
  exit 0
fi

# --- Check for implementation keywords in prompt and description ---
# Japanese keywords (no word boundary needed - multi-byte chars don't partial-match)
JP_IMPL='(実装|作成|変更|追加|削除|更新|修正|リファクタ)'
# English keywords (word boundary \b prevents "add" matching "address", etc.)
EN_IMPL='\b(Edit|Write|implement|create|modify|refactor|build|add|remove|update|delete|fix)\b'
check_text="${prompt} ${description}"

if echo "$check_text" | grep -qiE "$JP_IMPL|$EN_IMPL"; then

  # Check if investigation keywords are present WITHOUT implementation keywords
  # → If both exist, still warn (mixed intent should favor Codex)
  echo "" >&2
  echo "⚠️ [WARNING] 実装タスクはCodex CLI経路Cでの委任を推奨します (ADR-004準拠)" >&2
  echo "" >&2
  echo "  WHY: ADR-004で「1タスク+長時間+自律+大規模な実装」はCodex CLI経路Cと定義" >&2
  echo "  FIX: codex exec または bash ~/.claude/scripts/codex-parallel.sh で委任" >&2
  echo "       調査後の軽微な実装など、明確な理由があればこのまま続行可" >&2
  echo "" >&2
fi

# Always exit 0 — warning only, never block
exit 0
