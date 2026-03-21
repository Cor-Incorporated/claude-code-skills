#!/bin/bash
# =============================================================================
# Post-Deploy Verification Hook (PostToolUse: Bash)
# =============================================================================
# After `gcloud run deploy` or `docker push` commands, injects a mandatory
# verification checklist into Claude's context. This ensures Claude NEVER
# reports deployment as complete without running verification.
#
# Triggered by:
#   PostToolUse on Bash commands matching gcloud/docker deploy patterns
#
# Exit codes:
#   0 = always succeeds, outputs additional context for Claude
# =============================================================================

set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Detect deployment commands
IS_CLOUD_RUN_DEPLOY=false
IS_DOCKER_PUSH=false
IS_KUBECTL_APPLY=false

if echo "$command" | grep -q 'gcloud run deploy'; then
    IS_CLOUD_RUN_DEPLOY=true
fi

if echo "$command" | grep -q 'docker push'; then
    IS_DOCKER_PUSH=true
fi

if echo "$command" | grep -q 'kubectl apply'; then
    IS_KUBECTL_APPLY=true
fi

# Only inject context for deployment commands
if ! $IS_CLOUD_RUN_DEPLOY && ! $IS_DOCKER_PUSH && ! $IS_KUBECTL_APPLY; then
    exit 0
fi

# Extract service/image info for context
SERVICE_NAME=""
IMAGE_NAME=""

if $IS_CLOUD_RUN_DEPLOY; then
    SERVICE_NAME=$(echo "$command" | grep -oE 'gcloud run deploy [a-zA-Z0-9_-]+' | awk '{print $4}' || echo "unknown")
fi

if $IS_DOCKER_PUSH; then
    IMAGE_NAME=$(echo "$command" | grep -oE 'docker push [^ ]+' | awk '{print $3}' || echo "unknown")
fi

# Output additional context as JSON
cat <<CONTEXT_EOF
{
  "additionalContext": "⚠️ DEPLOYMENT DETECTED — 検証必須 ⚠️\n\nデプロイコマンドが実行されました。完了報告の前に以下を必ず実行してください:\n\n## 必須チェックリスト\n\n### フロントエンド (SPA/Frontend) デプロイの場合:\n1. \`./scripts/verify-spa-deployment.sh <DEPLOYED_URL>\` を実行\n2. バンドル内に \`http://\` URL がないことを確認 (Mixed Content)\n3. バンドル内にハードコード IP がないことを確認\n4. STT プロキシモードが有効であることを確認\n5. webapp-testing スキルまたは curl でブラウザ動作確認\n\n### バックエンド (API) デプロイの場合:\n1. ヘルスエンドポイント (\`/v1/healthz\`) の疎通確認\n2. 環境変数が正しく設定されているか \`gcloud run services describe\` で確認\n3. Cloud Run ログに起動エラーがないか確認\n\n### GKE (k8s) デプロイの場合:\n1. Pod が Running 状態であることを確認\n2. \`kubectl logs\` でエラーがないことを確認\n3. Service/Ingress の疎通確認\n\n### Docker ビルド & Push の場合:\n1. ビルド引数 (build-arg) を確認 — HTTP URL がハードコードされていないか\n2. HTTPS 環境にデプロイするなら、ビルド引数に http:// URL を含めない\n3. マルチプラットフォーム (\`--platform linux/amd64\`) を確認\n\n⚠️ このチェックリストを完了するまで「デプロイ完了」と報告してはいけません。"
}
CONTEXT_EOF
