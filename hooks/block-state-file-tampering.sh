#!/bin/bash
# block-state-file-tampering.sh
# PreToolUse hook: 状態ファイルへの直接書き込みをブロック
#
# 根本原因 (2026-03-21):
#   Claude Code が review-status.json に手動で true を書き込んで
#   レビューゲートをバイパスした事故の再発防止。
#   状態ファイルは hook スクリプトのみが更新すべき。
#
# 対象: Edit, Write ツール

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# 保護対象の状態ファイル一覧
PROTECTED_FILES=(
  "review-status.json"
  "pr-review-lock.json"
  "context-budget.json"
  "factcheck-state.json"
  "pr-gate-diagnostic.log"
)

for protected in "${PROTECTED_FILES[@]}"; do
  if [ "$BASENAME" = "$protected" ]; then
    cat >&2 <<ERRMSG

⛔ [BLOCKED] 状態ファイルへの直接書き込みを拒否

ファイル: $FILE_PATH
理由: $BASENAME はレビューゲート/品質ゲートの状態ファイルです。
      直接書き込みはゲートバイパスにあたるため禁止されています。

正しい方法:
  - review-status.json → code-reviewer実行後に record-code-review.sh が自動更新
  - pr-review-lock.json → pr-ci-review-gate.sh が POST_PUSH モードで自動設定
  - context-budget.json → context-budget-reset.sh がセッション開始時に初期化

📋 2026-03-21事故: AI が review-status.json に手動で true を書き込み、
   レビュー未実施のまま PR を作成。ゲートの存在意義を無にした。

ERRMSG
    exit 2
  fi
done

exit 0
