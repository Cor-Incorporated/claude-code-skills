#!/bin/bash
# block-state-file-tampering-bash.sh
# PreToolUse hook: Bash経由の状態ファイル改ざんをブロック
#
# python3 -c "json.dump(...)" や jq で review-status.json 等を
# 直接書き換えるパターンを検出してブロックする。

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CMD_FIRST_LINE=$(echo "$CMD" | head -1)

# 保護対象のファイル名パターン
PROTECTED="review-status\.json|pr-review-lock\.json|context-budget\.json|factcheck-state\.json|rebase-session\.json"

# Bashコマンドが保護対象ファイルに書き込むか検出
if echo "$CMD_FIRST_LINE" | grep -qE "$PROTECTED"; then
  # 読み取り操作（cat, jq -r で読むだけ）は許可
  if echo "$CMD_FIRST_LINE" | grep -qE '^\s*(cat|jq\s+-r|python3\s+-c.*json\.load|less|head|tail)\s'; then
    exit 0
  fi
  # 書き込みパターンを検出
  if echo "$CMD" | grep -qE '(>|json\.dump|echo.*>|tee|sed\s+-i|write_text|open.*\"w\")'; then
    cat >&2 <<ERRMSG

⛔ [BLOCKED] Bash経由の状態ファイル改ざンを検出

コマンド: $(echo "$CMD_FIRST_LINE" | head -c 120)
理由: ゲート状態ファイルへの直接書き込みは禁止されています。

正しい方法:
  - review-status.json → code-reviewer実行 → record-code-review.sh が自動更新
  - pr-review-lock.json → git push → pr-ci-review-gate.sh が自動設定

📋 AI自己バイパス防止ルール (2026-03-21追加)

ERRMSG
    exit 2
  fi
fi

exit 0
