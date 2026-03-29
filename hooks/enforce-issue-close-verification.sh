#!/bin/bash
# enforce-issue-close-verification.sh
# PreToolUse hook: gh issue close 実行前に受入基準検証を強制
#
# 根本原因 (2026-03-07):
#   「関連コードが存在する ≠ 受入基準を満たしている」
#   7件中6件を誤クローズした事故の再発防止
#
# Bug fix (#199, 2026-03-29):
#   Bug 1: --reason "not planned" (重複/統合クローズ) を検出してスキップ
#   Bug 2: 引用文字列を除去してから issue close パターンをマッチし誤検出を防止

set -euo pipefail

# Extract command from stdin JSON
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Bug 2 fix: 引用文字列を除去してからコマンド部分のみでissue番号を抽出
# --body "..." や --comment "..." 内の誤マッチを防ぐ
CMD_FLAT=$(echo "$COMMAND" | tr '\n' ' ')
CMD_NO_QUOTES=$(echo "$CMD_FLAT" | sed 's/"[^"]*"//g' | sed "s/'[^']*'//g")
ISSUE_NUM=$(echo "$CMD_NO_QUOTES" | grep -oE 'issue close [0-9]+' | grep -oE '[0-9]+' || true)

if [ -z "$ISSUE_NUM" ]; then
  exit 0
fi

# Bug 1 fix: --reason/-r "not planned" は証拠不要（重複/統合クローズ）
# P1: --comment内の偽--reasonパターンを除外するため、--comment/-c引数を先に除去
# P2: -r (短縮形) もサポート
CMD_FOR_REASON=$(echo "$CMD_FLAT" | sed 's/--comment "[^"]*"//g; s/-c "[^"]*"//g' | sed "s/--comment '[^']*'//g; s/-c '[^']*'//g")
CLOSE_REASON=$(echo "$CMD_FOR_REASON" | sed -En 's/.*(--reason|-r)[= ]"([^"]*)".*/\2/p')
if [ -z "$CLOSE_REASON" ]; then
  CLOSE_REASON=$(echo "$CMD_FOR_REASON" | sed -En "s/.*(--reason|-r)[= ]'([^']*)'.*/\2/p")
fi
if [ "$CLOSE_REASON" = "not planned" ]; then
  exit 0
fi

# Check if the close comment contains verification evidence
# Extract comment from -c "..." or --comment "..." (BSD compatible, no grep -P)
COMMENT=$(echo "$CMD_FLAT" | sed -En 's/.*(--comment|-c) "([^"]*)".*/\2/p')
if [ -z "$COMMENT" ]; then
  # Try single-quoted variant: -c '...'
  COMMENT=$(echo "$CMD_FLAT" | sed -En "s/.*(--comment|-c) '([^']*)'.*/\2/p")
fi
if [ -z "$COMMENT" ]; then
  # No explicit comment flag found — use entire command for pattern matching
  COMMENT="$CMD_FLAT"
fi

# Required patterns in the close comment
HAS_FILE_EVIDENCE=false
HAS_METRIC_OR_TEST=false
HAS_ACCEPTANCE_CHECK=false

# Check for file:line evidence (e.g., "file.py:42" or "lines 10-20")
if echo "$COMMENT" | grep -qE '(:[0-9]+|lines? [0-9]+-?[0-9]*)'; then
  HAS_FILE_EVIDENCE=true
fi

# Check for metric/test evidence (e.g., "pass_rate: 1.0" or "テスト済み" or "confirmed")
if echo "$COMMENT" | grep -qiE '(pass_rate|score|metric|テスト|test|確認済み|verified|✅)'; then
  HAS_METRIC_OR_TEST=true
fi

# Check for acceptance criteria acknowledgment
if echo "$COMMENT" | grep -qiE '(受入基準|acceptance|criteria|要件|requirement|全項目)'; then
  HAS_ACCEPTANCE_CHECK=true
fi

# Require ALL THREE types of evidence
MISSING=""
if [ "$HAS_FILE_EVIDENCE" = false ]; then
  MISSING="${MISSING}\n  - ファイルパス+行番号の証拠 (例: backend/main.py:277)"
fi
if [ "$HAS_METRIC_OR_TEST" = false ]; then
  MISSING="${MISSING}\n  - テスト/メトリクスの証拠 (例: pass_rate: 1.0, テスト済み)"
fi
if [ "$HAS_ACCEPTANCE_CHECK" = false ]; then
  MISSING="${MISSING}\n  - 受入基準の全項目照合 (例: '受入基準全項目確認済み')"
fi

if [ -n "$MISSING" ]; then
  cat >&2 <<ERRMSG

⛔ Issue #${ISSUE_NUM} クローズをブロック

gh issue close を実行する前に、以下の3つの証拠がクローズコメントに必要です:
${MISSING}

📋 必須チェックリスト:
  1. gh issue view ${ISSUE_NUM} でIssue本文を読む
  2. 受入基準を1つずつリストアップ
  3. 各基準に対して実コード/テスト結果/メトリクス値で検証
  4. 「関連コードがある」≠「受入基準を満たしている」

💡 コメント例:
  gh issue close ${ISSUE_NUM} --comment "受入基準全項目確認済み。修正箇所: src/foo.go:42, テスト済み (pass_rate: 1.0)"

🔴 2026-03-07事故: 7件中6件を誤クローズ
   原因: 「コードが存在する」だけで「実装済み」と判断

ERRMSG
  exit 2
fi

exit 0
