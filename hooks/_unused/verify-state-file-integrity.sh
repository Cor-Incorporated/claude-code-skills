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
  # 初回実行: ベースラインを作成して次回から検証開始
  for f in "${STATE_DIR}/review-status.json" "${STATE_DIR}/pending-review-comments.json" "${STATE_DIR}/pr-review-lock.json" "${STATE_DIR}/pr-review-read.json" "${STATE_DIR}/context-budget.json" "${STATE_DIR}/factcheck-status.json" "${STATE_DIR}/rebase-session.json" "${STATE_DIR}/pr-gate-diagnostic.log"; do
    if [[ -f "$f" ]]; then
      sha=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)
      echo "${f}|${sha}" >> "$INTEGRITY_FILE"
    fi
  done
  exit 0
fi

# 現在のチェックサムを計算して比較
while IFS='|' read -r file expected_sha; do
  if [[ -f "$file" ]]; then
    current_sha=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    if [[ "$current_sha" != "$expected_sha" ]] && [[ -n "$expected_sha" ]]; then
      # 監査ログに記録（正規hookによる変更の可能性もあるため、stderrには出力しない）
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INTEGRITY_CHANGE file=$file expected=$expected_sha actual=$current_sha" >> "${STATE_DIR}/tampering-audit.log" 2>/dev/null || true
    fi
  fi
done < "$INTEGRITY_FILE"

# 削除検出: ベースラインにあるがファイルが存在しない場合
while IFS='|' read -r file expected_sha; do
  if [[ ! -f "$file" ]] && [[ -n "$expected_sha" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INTEGRITY_DELETION file=$file" >> "${STATE_DIR}/tampering-audit.log" 2>/dev/null || true
  fi
done < "$INTEGRITY_FILE"

# チェックサムを更新（次回比較用）
true > "$INTEGRITY_FILE"
for f in "${STATE_DIR}/review-status.json" "${STATE_DIR}/pending-review-comments.json" "${STATE_DIR}/pr-review-lock.json" "${STATE_DIR}/pr-review-read.json" "${STATE_DIR}/context-budget.json" "${STATE_DIR}/factcheck-status.json" "${STATE_DIR}/rebase-session.json" "${STATE_DIR}/pr-gate-diagnostic.log"; do
  if [[ -f "$f" ]]; then
    sha=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)
    echo "${f}|${sha}" >> "$INTEGRITY_FILE"
  fi
done

exit 0
