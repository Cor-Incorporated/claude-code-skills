#!/bin/bash
# enforce-factcheck-before-user-request.sh
# BLOCKING: ユーザーへの手動操作依頼前にファクトチェックを強制
#
# トリガー: AskUserQuestion ツール使用時
# 目的: 以下を検出して停止
#   1. ダッシュボード操作の依頼（CI/CDで自動化すべき）
#   2. 手動設定変更の依頼（API/CLIで自動化すべき）
#   3. ファクトチェックなしの提案
set -euo pipefail

input=$(cat)
question=$(echo "$input" | jq -r '.tool_input.question // ""' 2>/dev/null || echo "")

BLOCKERS=()

# ダッシュボード操作の依頼を検出
if echo "$question" | grep -qi "ダッシュボード\|dashboard\|UI.*設定\|UI.*変更\|手動.*設定\|手動.*変更\|手動.*操作"; then
    BLOCKERS+=("[BLOCK] ユーザーにダッシュボード/手動操作を依頼しようとしています。CI/CD、CLI、APIで自動化できないか先に確認してください。自動化不可能な場合のみ、公式ドキュメントのURLを添えて依頼してください。")
fi

# 「〜してください」「〜をお願い」で設定変更を依頼する場合
if echo "$question" | grep -qi "設定.*してください\|変更.*してください\|操作.*お願い\|設定.*お願い"; then
    BLOCKERS+=("[BLOCK] ユーザーへの設定変更依頼を検出。まず以下を確認: (1) API/CLIで自動化可能か (2) 公式ドキュメントで手順を確認済みか (3) そのUI/設定が実際に存在するか")
fi

if [ ${#BLOCKERS[@]} -gt 0 ]; then
    echo "🚫 ファクトチェック未完了の手動操作依頼を検出:"
    for b in "${BLOCKERS[@]}"; do
        echo "  $b"
    done
    echo ""
    echo "対応: WebSearch/公式ドキュメントで事実確認 → 自動化検討 → 自動化不可能な場合のみ依頼"
    exit 1
fi

exit 0
