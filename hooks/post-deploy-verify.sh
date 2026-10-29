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

# Recall first: a missed checklist after a real deploy costs more than an
# extra one. The phrase counts anywhere in the command (as before) except
#   - inside a heredoc body (a document being written, not run), and
#   - as the quoted pattern/text of grep/rg/ag/echo/printf.
# 2026-10-30 harness-pdca: a python heredoc that edited the README (its body
# mentioned the deploy words) printed DEPLOYMENT DETECTED. A first fix that
# demanded command position missed `for … do docker push`, `then gcloud run
# deploy`, `sudo -E`, `timeout 900`, `bash -c "kubectl apply …"` (review of
# #445); those stay detected here. tests/test-post-deploy-verify.sh
# Known limit: a heredoc fed to python (or another non-shell interpreter) is
# treated as text, so `python3 - <<PY … os.system("kubectl apply …")` gets no
# checklist. That body is where the README false positive came from.
case "$command" in
  *"gcloud run deploy"*|*"docker push"*|*"kubectl apply"*) ;;
  *) exit 0 ;;
esac

# Python source kept out of $( ): bash 3.2 mis-parses quotes inside a
# heredoc there (tests/test-hooks-bash32-syntax.sh).
_hits_py=""
IFS= read -r -d '' _hits_py <<'PY' || true
import re
import sys

cmd = sys.argv[1]
# A heredoc starts at `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"` preceded by
# whitespace or line start. `<<<` (here-string) and `1<<n` (shift) are not.
start = re.compile(r"(?:^|\s)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1(?![A-Za-z0-9_])")
out, term = [], None
for line in cmd.split("\n"):
    if term is not None:
        if line.strip() == term:
            term = None
        continue
    m = start.search(line)
    before = line[: m.start()] if m else ""
    in_arith = before.count("$((") > before.count("))")
    # A heredoc fed to a shell or to ssh is run, so its body counts.
    after = line[m.end():] if m else ""
    # A << inside quotes on this line is text, not a heredoc start.
    # $( opens a new quoting context: `-m "$(cat <<'EOF'` is a real heredoc.
    ctx = before.rsplit("$(", 1)[-1]
    in_quotes = m is not None and (ctx.count('"') % 2 == 1 or ctx.count("'") % 2 == 1)
    run_by_shell = re.search(r"(?:^|[\s;&|(])(?:\S*/)?(?:bash|sh|zsh|dash|ssh|sudo)(?:\s|$)", before) or re.search(
        r"\|\s*(?:\S+\s+)*?(?:\S*/)?(?:bash|sh|zsh|dash|ssh)(?:\s|$)", after
    )
    if m and not in_arith and not in_quotes and not run_by_shell and "<<<" not in line[m.start():m.end() + 1]:
        term = m.group(2)
    out.append(line)
text = "\n".join(out)
def drop_quoted(m):
    quoted = m.group(1)
    # Double quotes still run $( ) and backticks.
    rest = m.string[m.end():].split("\n", 1)[0]
    if re.search(r"\|\s*(?:\S*/)?(?:bash|sh|zsh|dash|ssh)\b", rest):
        return m.group(0)  # the text is piped into a shell and run
    if quoted.startswith('"') and ("$(" in quoted or chr(96) in quoted):  # chr(96): bash 3.2
        return m.group(0)
    return " "


text = re.sub(
    r"\b(?:grep|egrep|fgrep|rg|ag|echo|printf)\b(?:\s+-{1,2}[A-Za-z][\w-]*(?:=\S+)?)*\s+('[^']*'|\"[^\"]*\")",
    drop_quoted, text)
found = [w for w in ("gcloud run deploy", "docker push", "kubectl apply") if w in text]
print(" ".join(w.split()[-1] for w in found))
PY
# If python cannot run, fail toward the checklist (recall first).
hits="$(python3 -c "$_hits_py" "$command" 2>/dev/null)" || hits="deploy push apply"

case " $hits " in *" deploy "*) IS_CLOUD_RUN_DEPLOY=true ;; esac
case " $hits " in *" push "*) IS_DOCKER_PUSH=true ;; esac
case " $hits " in *" apply "*) IS_KUBECTL_APPLY=true ;; esac

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
