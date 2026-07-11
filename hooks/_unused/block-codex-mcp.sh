#!/bin/bash
# block-codex-mcp.sh — PreToolUse hook (matcher: mcp__codex__.*)
# =========================================================================
# Issue #72: Enforce Codex CLI-only usage (block MCP)
#
# Ref: delegation.md — "Codex MCP使用禁止 — CLI経由のみ（Ref: Issue #11）"
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PreToolUse (matcher supports regex on tool name)
#   Exit 2 = block the tool call
#
# Why: Codex MCP has limitations vs CLI:
#   - No sandbox isolation
#   - No worktree support
#   - No task file input
#   - Inconsistent behavior reported (Issue #11)
# =========================================================================

set -euo pipefail

echo "" >&2
echo "[BLOCKED] Codex MCP (mcp__codex__*) の使用は禁止されています。" >&2
echo "" >&2
echo "理由: delegation.md — 'Codex MCP使用禁止 — CLI経由のみ (Ref: Issue #11)'" >&2
echo "" >&2
echo "代替方法 (Codex CLI):" >&2
echo "  レビュー:  codex exec review --base develop" >&2
echo "  実装委任:  bash ~/.claude/scripts/codex-parallel.sh <repo> <branch> '<prompt>'" >&2
echo "  対話:      codex exec '<question>'" >&2
echo "" >&2
exit 2
