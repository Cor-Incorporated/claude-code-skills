#!/bin/bash
# verify-state-file-integrity.sh
# PostToolUse hook: Bash実行後に状態ファイルの整合性を検証
#
# 設計: TOCTOU防止
# PreToolUse hookをバイパスして状態ファイルが改ざんされた場合を検出。
# hookスクリプト自身による正規書き込みはSHA記録で区別。
#
# Issue #157 追加対策: post-execution integrity verification

set -euo pipefail

# 保護対象ファイル
STATE_DIR="${HOME}/.claude/state"
INTEGRITY_FILE="${STATE_DIR}/.integrity-checksums"

# 整合性チェックファイルがなければ初期化
if [[ ! -f "$INTEGRITY_FILE" ]]; then
  exit 0
fi

# 現在のチェックサムを計算して比較
CHANGED="false"
while IFS='|' read -r file expected_sha; do
  if [[ -f "$file" ]]; then
    current_sha=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    if [[ "$current_sha" != "$expected_sha" ]] && [[ -n "$expected_sha" ]]; then
      CHANGED="true"
      echo "⚠️  [INTEGRITY] 状態ファイル改ざん検出: $file" >&2
      echo "  期待SHA: $expected_sha" >&2
      echo "  現在SHA: $current_sha" >&2
      # 監査ログに記録
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INTEGRITY_VIOLATION file=$file expected=$expected_sha actual=$current_sha" >> "${STATE_DIR}/tampering-audit.log" 2>/dev/null || true
    fi
  fi
done < "$INTEGRITY_FILE"

if [[ "$CHANGED" == "true" ]]; then
  echo "" >&2
  echo "📋 状態ファイルがBashコマンド実行後に変更されました。" >&2
  echo "   正規hookスクリプト以外による変更の可能性があります。" >&2
  echo "   監査ログ: ${STATE_DIR}/tampering-audit.log" >&2
fi

# チェックサムを更新（次回比較用）
true > "$INTEGRITY_FILE"
for f in "${STATE_DIR}/review-status.json" "${STATE_DIR}/pr-review-lock.json" "${STATE_DIR}/pr-review-read.json" "${STATE_DIR}/context-budget.json" "${STATE_DIR}/factcheck-status.json" "${STATE_DIR}/rebase-session.json"; do
  if [[ -f "$f" ]]; then
    sha=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)
    echo "${f}|${sha}" >> "$INTEGRITY_FILE"
  fi
done

exit 0
