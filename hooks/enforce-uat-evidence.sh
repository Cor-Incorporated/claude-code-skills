#!/bin/bash
# enforce-uat-evidence.sh
# PreToolUse(Bash): UAT/UX/E2E/browser completion claims need concrete evidence.

set -euo pipefail

input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

if [[ -z "$input" ]]; then
  exit 0
fi

COMMAND=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

FIRST_LINE=$(printf '%s\n' "$COMMAND" | head -n 1)

is_inspection_command() {
  local cmd="$1"

  [[ "$cmd" != *$'\n'* ]] || return 1
  if printf '%s' "$cmd" | grep -qE '[;&`<>]|\$\('; then
    return 1
  fi
  printf '%s' "$cmd" | grep -qE '^[[:space:]]*(rg|grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|sed|awk|find|git[[:space:]]+status)\b'
}

has_uat_context() {
  printf '%s' "$COMMAND" | grep -Eiq '(UAT|UX|E2E|操作テスト|ブラウザ|browser|browser[-[:space:]]+test|ユーザー?[[:space:]-]*ジャーニー|UI[[:space:]-]*(proof|evidence|検証|確認)|live[[:space:]-]+verification|ライブ検証|本番検証|β[[:space:]]*Ready|Beta[[:space:]]*Ready)'
}

has_completion_claim() {
  printf '%s' "$COMMAND" | grep -Eiq '(完了|完遂|テスト済み?|検証済み?|確認済み?|通過|合格|解決|修正済|close[[:space:]]*可能|ready[[:space:]]+to[[:space:]]+close|ready[[:space:]]+for[[:space:]]+(merge|review)|PR[[:space:]-]*ready|β[[:space:]]*Ready|Beta[[:space:]]*Ready|Issue[[:space:]]*close|クローズ|マージ|merged?|mergeable|completed?|done|resolved|fixed|verified|validated|passed|passing)'
}

is_github_guarded_operation() {
  printf '%s' "$COMMAND" | grep -Eiq '(^|[;&|[:space:]])gh[[:space:]]+issue[[:space:]]+(create|comment|close)\b|(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+(create|comment|review|merge|ready)\b'
}

is_terminal_github_operation() {
  printf '%s' "$COMMAND" | grep -Eiq '(^|[;&|[:space:]])gh[[:space:]]+issue[[:space:]]+close\b|(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+(merge|ready)\b'
}

is_blocker_or_unverified_status() {
  ! is_terminal_github_operation &&
    printf '%s' "$COMMAND" | grep -Eiq '(未検証|未確認|未完了|未実施|未テスト|blocker|blocked|blocking|unverified|not[[:space:]-]+verified|not[[:space:]-]+tested|cannot[[:space:]-]+verify|要検証|要確認|確認待ち|証跡不足|証跡待ち|証跡なし|失敗|failed|failure|NG|red|エラー|不具合|バグ|close不可|クローズ不可)'
}

is_completion_like_command() {
  printf '%s' "$COMMAND" | grep -Eiq '(^|[;&|])[[:space:]]*(echo|printf|cat[[:space:]]*<<|tee|pbcopy|osascript)\b'
}

has_full_evidence() {
  local has_label=false
  local has_execution=false
  local has_artifact=false
  local has_outcome=false

  if printf '%s' "$COMMAND" | grep -Eiq '(evidence|証拠|根拠|確認結果|検証結果|verification|verified|確認済み?|検証済み?)'; then
    has_label=true
  fi
  if printf '%s' "$COMMAND" | grep -Eiq '(playwright|cypress|selenium|browser|ブラウザ|操作テスト|E2E|UAT|UX|lighthouse|manual|手動|npx|npm[[:space:]]+run|pnpm|yarn|bun|pytest|curl)'; then
    has_execution=true
  fi
  if printf '%s' "$COMMAND" | grep -Eiq '(https?://|screenshot|スクリーンショット|video|録画|trace|artifact|HAR|ログ|log|stdout|標準出力|exit[[:space:]]+0|pass_rate|[^[:space:]]+\.(png|jpe?g|webm|mp4|mov|zip|har|trace|log))'; then
    has_artifact=true
  fi
  if printf '%s' "$COMMAND" | grep -Eiq '(PASS|passed|passing|成功|OK|green|exit[[:space:]]+0|確認済み?|verified|テスト済み?|完了|pass_rate[[:space:]:=]+1(\.0)?)'; then
    has_outcome=true
  fi

  [[ "$has_label" == true && "$has_execution" == true && "$has_artifact" == true && "$has_outcome" == true ]]
}

if ! has_uat_context; then
  exit 0
fi

if is_inspection_command "$FIRST_LINE"; then
  exit 0
fi

if is_blocker_or_unverified_status; then
  exit 0
fi

if ! has_completion_claim && ! is_terminal_github_operation; then
  exit 0
fi

if ! is_github_guarded_operation && ! is_completion_like_command; then
  exit 0
fi

if has_full_evidence; then
  exit 0
fi

cat >&2 <<'ERRMSG'

🚫 [BLOCKED] UAT/UX/E2E/ブラウザ完了主張に証拠が不足しています

UAT・操作テスト・E2E・ブラウザ確認・β Ready・Issue close などを
gh issue create/comment/close、gh pr merge、または完了報告系の shell
command に含める場合は、本文に以下を含めてください:

  - 証拠ラベル: Evidence / 証拠 / 検証結果 / 確認結果
  - 実行面: Playwright/Cypress/ブラウザ/手動操作テスト/実行コマンド
  - 具体物: URL、スクリーンショット、録画、trace、log、exit 0 など
  - 結果: PASS / passed / 成功 / 確認済み

ブロッカー・未検証・失敗を報告する gh issue create/comment は許可されます。

例:
  Evidence: Playwright browser E2E passed.
  Command: npx playwright test tests/e2e/login.spec.ts (exit 0)
  URL: https://example.com
  Screenshot: artifacts/uat-login.png

ERRMSG

exit 2
