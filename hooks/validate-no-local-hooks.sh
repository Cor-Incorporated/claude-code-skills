#!/bin/bash
# validate-no-local-hooks.sh — Prevent hooks in settings.local.json
# =================================================================
# settings.local.json に hooks セクションがあると、グローバルの hooks を
# 完全に上書きしてしまう。このスクリプトはセッション開始時に検出して警告する。
# =================================================================

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"
_aidd_block() {
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "validate-no-local-hooks" "block" "deny" "settings.local.json hooks" "local-hooks-present"
  fi
  exit 2
}

LOCAL_SETTINGS="$HOME/.claude/settings.local.json"

if [[ ! -f "$LOCAL_SETTINGS" ]]; then
  exit 0
fi

if command -v jq &>/dev/null; then
  HAS_HOOKS=$(jq 'has("hooks")' "$LOCAL_SETTINGS" 2>/dev/null)
  if [[ "$HAS_HOOKS" == "true" ]]; then
    HOOK_COUNT=$(jq '[.hooks | to_entries[] | .value | length] | add // 0' "$LOCAL_SETTINGS" 2>/dev/null)
    echo "" >&2
    echo "⚠️  [CRITICAL] settings.local.json に hooks セクションが検出されました！" >&2
    echo "   これはグローバル settings.json の全フック ($HOOK_COUNT 個) を上書きします。" >&2
    echo "   PR merge gate, review gate 等の保護が無効化されます。" >&2
    echo "" >&2
    echo "   修正方法:" >&2
    echo "   1. local の hooks をグローバルに移動" >&2
    echo "   2. settings.local.json から hooks セクションを削除" >&2
    echo "" >&2
    # Block session start to force fix
    _aidd_block
  fi
fi

exit 0
