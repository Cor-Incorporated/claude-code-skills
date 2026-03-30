#!/usr/bin/env bash
# enforce-codex-delegation.sh — Warn when Agent used for Codex-appropriate tasks (#208)
# PreToolUse hook on Agent matcher. Advisory only (exit 0 always).
set -euo pipefail

[[ "${CLAUDE_AGENT_DEPTH:-0}" -ge 1 ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
[[ "$TOOL_NAME" == "Agent" ]] || exit 0

PROMPT=$(echo "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ti=d.get('tool_input',{})
if isinstance(ti,str):
    try: ti=json.loads(ti)
    except (json.JSONDecodeError, ValueError, TypeError): ti={}
print(ti.get('prompt',''))
" 2>/dev/null || echo "")
SUBAGENT_TYPE=$(echo "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ti=d.get('tool_input',{})
if isinstance(ti,str):
    try: ti=json.loads(ti)
    except (json.JSONDecodeError, ValueError, TypeError): ti={}
print(ti.get('subagent_type',''))
" 2>/dev/null || echo "")

case "$SUBAGENT_TYPE" in
  code-reviewer|security-reviewer|feature-dev:code-reviewer|feature-dev:code-explorer|feature-dev:code-architect|claude-code-harness:*|Explore|Plan)
    exit 0 ;;
esac

if echo "$PROMPT" | grep -qiE '(調査|検索|search|find|explore|read|確認|check|analyze|分析)' && \
   ! echo "$PROMPT" | grep -qiE '(implement|実装|create|作成|fix|修正|refactor|write|書)'; then
  exit 0
fi

REASON=""

REFACTOR_KW=$(echo "$PROMPT" | grep -ciE '(refactor|unif|migrat|全体|一貫|統合|横断|リファクタ|移行)' || true)
FILE_IND=$(echo "$PROMPT" | { grep -oE '[a-zA-Z0-9_/-]+\.(sh|ts|tsx|js|jsx|py|go|rs|md)' || true; } | wc -l | tr -d ' ')
NUMERIC_FILES=$(echo "$PROMPT" | { grep -oE '[0-9]+\s*(files?|ファイル)' || true; } | { grep -oE '[0-9]+' || true; } | awk '{s+=$1} END {print s+0}')
FILE_IND=$((FILE_IND + NUMERIC_FILES))
if [[ "$REFACTOR_KW" -gt 0 ]] && [[ "$FILE_IND" -ge 3 ]]; then
  REASON="横断的リファクタリング (${FILE_IND}ファイル参照 + refactorキーワード)"
fi

if [[ -z "$REASON" ]]; then
  if echo "$PROMPT" | grep -qiE '(全体を理解|全ファイル|full codebase|entire|1[0-9]{3,}\s*(行|lines)|all files|全コード)'; then
    REASON="大規模コンテキスト必要 (全体理解/1000行+ 検出)"
  fi
fi

if [[ -z "$REASON" ]]; then
  if echo "$PROMPT" | grep -qiE '(impl.*test.*lint|テスト→修正|test.*fix.*re-?test|iterati|繰り返|ループ|反復|implement.*then.*test|実装.*テスト.*修正)'; then
    REASON="反復サイクル (impl→test→fix ループ検出)"
  fi
fi

[[ -z "$REASON" ]] && exit 0

echo "⚠️ [delegation] このタスクは Codex CLI 経路C が適切な可能性があります。" >&2
echo "  理由: $REASON" >&2
echo "  基準: 変更ファイル3+/コンテキスト1000行+/反復サイクル" >&2
echo "  → scripts/codex-parallel.sh で委任を検討してください。" >&2
exit 0
