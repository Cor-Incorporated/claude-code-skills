#!/bin/bash
# enforce-post-merge-validation.sh — PostToolUse hook: notify post-merge validation for infra changes
# =========================================================================
# After gh pr merge completes, checks if the merged PR contained high-risk
# changes (migration, Terraform, deploy workflows, Docker) and notifies
# via additionalContext to run post-merge validation checklist.
#
# Rules (quality.md):
#   - migration/Terraform/Cloud Run/release workflowを含む変更は
#     PRごとにpost-merge validation手順を持つ
#   - 本番障害対応のfixをmerge → 再発防止テストまたは監視を即追加
#
# PostToolUse hook — cannot block (tool already ran), but can add context
# Exit 0 + JSON additionalContext to notify Claude
# =========================================================================
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only act on gh pr merge commands
cmd_first=$(echo "$cmd" | head -1)
if ! echo "$cmd_first" | grep -qE 'gh\s+pr\s+merge\b'; then
  exit 0
fi

# --- Extract PR number ---
PR_NUM=$(echo "$cmd" | grep -oE 'gh\s+pr\s+merge\s+([0-9]+)' | grep -oE '[0-9]+' || echo "")
if [[ -z "$PR_NUM" ]]; then
  exit 0
fi

# --- Get changed files from the merged PR ---
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
if [[ -z "$REPO" ]]; then
  exit 0
fi

CHANGED_FILES=$(gh api "repos/${REPO}/pulls/${PR_NUM}/files" --jq '.[].filename' 2>/dev/null || echo "")
if [[ -z "$CHANGED_FILES" ]]; then
  exit 0
fi

# --- Detect high-risk change categories ---
RISKS=()

if echo "$CHANGED_FILES" | grep -qE '^terraform/|\.tf$'; then
  RISKS+=("Terraform")
fi

if echo "$CHANGED_FILES" | grep -qiE '^migration/|migrate|\.sql$'; then
  RISKS+=("Migration/DDL")
fi

if echo "$CHANGED_FILES" | grep -qE '^\.github/workflows/'; then
  RISKS+=("GitHub Actions Workflow")
fi

if echo "$CHANGED_FILES" | grep -qiE '^Dockerfile|^docker-compose|cloudbuild'; then
  RISKS+=("Docker/Cloud Build")
fi

if echo "$CHANGED_FILES" | grep -qiE 'deploy|release'; then
  RISKS+=("Deploy/Release")
fi

# --- No high-risk changes detected ---
if [[ ${#RISKS[@]} -eq 0 ]]; then
  exit 0
fi

# --- Build notification via additionalContext ---
RISK_LIST=$(printf "  - %s\n" "${RISKS[@]}")
CONTEXT="⚠️ [POST-MERGE VALIDATION] PR #${PR_NUM} に高リスク変更が含まれています。

検出カテゴリ:
${RISK_LIST}

以下のチェックリストを実行してください:
  □ HTTP 200 レスポンス確認
  □ HTTPS 強制確認
  □ ログにエラーなし
  □ Mixed Content なし
  □ migration: rollback手順が明記されているか
  □ Terraform: plan結果がPRに貼り付けられているか
  □ Docker: --platform linux/amd64 (Apple Silicon→GCP)
  □ Workflow: 最低1回の手動smoke通過

quality.md: post-merge検証ルール"

# Output JSON with additionalContext
jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
