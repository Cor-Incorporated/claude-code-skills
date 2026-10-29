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

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Detect deployment commands
IS_CLOUD_RUN_DEPLOY=false
IS_DOCKER_PUSH=false
IS_KUBECTL_APPLY=false

# Match only where the words are run as a command, not where they are text.
# 2026-10-30 harness-pdca: a python heredoc that edited this README (its body
# mentioned `gcloud run deploy` / `docker push`) printed DEPLOYMENT DETECTED.
# Heredoc bodies are dropped, and a hit must sit at the start of a command
# (after ; & | ( or a newline, past env assignments / sudo / time).
# tests/test-post-deploy-verify.sh
deploy_hit() { # $1 = command text, $2 = "word word" → exit 0 when run as a command
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import re
import sys

cmd, words = sys.argv[1], sys.argv[2].split()
out, term = [], None
for line in cmd.split("\n"):
    if term is not None:
        if line.strip() == term:
            term = None
        continue
    out.append(line)
    m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
    if m:
        term = m.group(2)
text = "\n".join(out)
pat = (r"(?:^|[;&|(\n]|\$\()\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+|time\s+|command\s+)*"
       + r"\s+".join(map(re.escape, words)) + r"\b")
raise SystemExit(0 if re.search(pat, text) else 1)
PY
}

if deploy_hit "$command" 'gcloud run deploy'; then
    IS_CLOUD_RUN_DEPLOY=true
fi

if deploy_hit "$command" 'docker push'; then
    IS_DOCKER_PUSH=true
fi

if deploy_hit "$command" 'kubectl apply'; then
    IS_KUBECTL_APPLY=true
fi

# Only inject context for deployment commands
if ! $IS_CLOUD_RUN_DEPLOY && ! $IS_DOCKER_PUSH && ! $IS_KUBECTL_APPLY; then
    exit 0
fi

if declare -F aidd_ledger_append >/dev/null 2>&1; then
  aidd_ledger_append "post-deploy-verify" "measure" "allow" "deploy-cmd" "deploy-checklist-injected"
fi

# Output additional context as JSON (hookSpecificOutput format)
CONTEXT_MSG="⚠️ DEPLOYMENT DETECTED — 検証必須 ⚠️\n\nデプロイコマンドが実行されました。完了報告の前に以下を必ず実行してください:\n\n## 必須チェックリスト\n\n### フロントエンド (SPA/Frontend) デプロイの場合:\n1. \`./scripts/verify-spa-deployment.sh <DEPLOYED_URL>\` を実行\n2. バンドル内に \`http://\` URL がないことを確認 (Mixed Content)\n3. バンドル内にハードコード IP がないことを確認\n4. STT プロキシモードが有効であることを確認\n5. webapp-testing スキルまたは curl でブラウザ動作確認\n\n### バックエンド (API) デプロイの場合:\n1. ヘルスエンドポイント (\`/v1/healthz\`) の疎通確認\n2. 環境変数が正しく設定されているか \`gcloud run services describe\` で確認\n3. Cloud Run ログに起動エラーがないか確認\n\n### GKE (k8s) デプロイの場合:\n1. Pod が Running 状態であることを確認\n2. \`kubectl logs\` でエラーがないことを確認\n3. Service/Ingress の疎通確認\n\n### Docker ビルド & Push の場合:\n1. ビルド引数 (build-arg) を確認 — HTTP URL がハードコードされていないか\n2. HTTPS 環境にデプロイするなら、ビルド引数に http:// URL を含めない\n3. マルチプラットフォーム (\`--platform linux/amd64\`) を確認\n\n⚠️ このチェックリストを完了するまで「デプロイ完了」と報告してはいけません。"

if command -v jq >/dev/null 2>&1; then
  # The message is written with \n escapes for the JSON fallback below; jq
  # needs real newlines or the reader sees a literal "\n".
  jq -n --arg ctx "$(printf '%b' "$CONTEXT_MSG")" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  cat <<CONTEXT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "$CONTEXT_MSG"
  }
}
CONTEXT_EOF
fi
