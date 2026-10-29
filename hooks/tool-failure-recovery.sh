#!/bin/bash
# tool-failure-recovery.sh — PostToolUseFailure hook
# =========================================================================
# Issue #66 Fix #6: Error recovery guidance on tool failure
#
# Ref: https://code.claude.com/docs/en/hooks
#   Event: PostToolUseFailure (matcher: tool name regex)
#   stdin: { tool_name, tool_input, error, is_interrupt, tool_use_id }
#   Exit 0 + JSON = additionalContext injected into conversation
#   Exit 2 = stderr shown to Claude (tool already failed, non-blocking)
#
# Logic:
#   1. Skip interrupted commands (is_interrupt=true)
#   2. Classify error by tool type and error pattern
#   3. Provide actionable recovery guidance via additionalContext
# =========================================================================

set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# Read stdin
input=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || echo "")
fi

[[ -z "$input" ]] && exit 0

# Require jq
command -v jq &>/dev/null || exit 0

# Skip interrupted commands (user Ctrl+C, etc.)
IS_INTERRUPT=$(echo "$input" | jq -r '.is_interrupt // false' 2>/dev/null || echo "false")
if [[ "$IS_INTERRUPT" == "true" ]]; then
  exit 0
fi

TOOL_NAME=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
ERROR_MSG=$(echo "$input" | jq -r '.error // ""' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$input" | jq -r '.tool_input // {}' 2>/dev/null || echo "{}")

# Skip if no useful info
[[ -z "$TOOL_NAME" ]] && exit 0
[[ -z "$ERROR_MSG" ]] && exit 0

# =========================================================================
# Error classification and recovery guidance
# =========================================================================
GUIDANCE=""

case "$TOOL_NAME" in
  Bash)
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null || echo "")
    # 2026-10-30 harness-pdca F4: the error field is "Exit code N" followed by
    # the command's combined stdout+stderr. Matching a phrase anywhere in it
    # misread grep output as errors ("command not found" inside a log being
    # searched), picked "zsh" out of zsh's "zsh: command not found: foo", and
    # called ssh's "Permission denied (publickey)" a file-permission problem.
    # Classify by exit code first, then only by lines shaped like an error
    # from the shell or the tool itself. tests/test-tool-failure-recovery.sh
    GUIDANCE="$(python3 - "$ERROR_MSG" "$CMD" <<'PY' 2>/dev/null || true
import re
import sys

err, cmd = sys.argv[1], sys.argv[2]
lines = err.splitlines()
m = re.match(r"Exit code (\d+)", lines[0] if lines else "")
code = int(m.group(1)) if m else None
body = lines[1:] if m else lines
SEARCH = {"grep", "egrep", "fgrep", "rg", "ag", "git-grep"}
first = ""
for seg in re.split(r"&&|\|\||;", cmd)[-1:]:
    words = [w for w in seg.strip().split() if "=" not in w.split("/")[0]]
    first = words[0].rsplit("/", 1)[-1] if words else ""

def missing_command():
    for line in body:
        for pat in (r"^(?:zsh|\(eval\):\d+): command not found: (\S+)$",
                    r"^(?:bash|sh)(?:: line \d+)?: (\S+): command not found$",
                    r"^/\S+: line \d+: (\S+): command not found$"):
            hit = re.match(pat, line.strip())
            if hit:
                return hit.group(1)
    return None

missing_paths = []
for line in body:
    hit = re.match(r"^(?:rg|grep|egrep|fgrep|ag|cat|ls|head|tail|wc|cp|mv|sed|awk|cd): (?:cannot access ')?(.+?)'?: No such file or directory", line.strip()) \
        or re.match(r"^\S+: can't open file '?(.+?)'?: \[Errno 2\] No such file or directory", line.strip())
    if hit:
        missing_paths.append(hit.group(1))

# A logged "bash: foo: command not found" in output is not this command's
# error unless the command itself exited 127.
name = missing_command() if code in (127, None) else None
if name:
    print(f"コマンド '{name}' が見つかりません (exit {code})。brew install / npm install -g / pip install で導入するか、代替コマンドを使用してください。")
elif code == 127:
    print("exit 127 = コマンドが見つかりません。PATH と綴りを確認してください (which <cmd>)。")
elif any(re.match(r"^\(eval\):\d+: =+ not found$", l.strip()) for l in body):
    print("zsh の = 展開です (行頭の = はコマンド名展開になる)。'=====' のように引用してください。コマンド不足ではありません。")
elif code == 126 or any(re.match(r"^(?:zsh|bash|sh)(?:: line \d+)?: permission denied: ", l.strip(), re.I) for l in body):
    print("実行権限がありません (exit 126)。ls -la で確認し、必要なら chmod +x か bash <script> で実行してください。")
elif any(re.search(r"Permission denied \((?:publickey|password|keyboard-interactive)", l) for l in body):
    print("SSH 認証の失敗です (ファイル権限ではありません)。ssh -v で使われた鍵と接続先ユーザーを確認してください。秘密鍵の中身は読まないこと。")
elif first in SEARCH and code == 1:
    pass  # 一致なし。エラーではない
elif first in SEARCH and code == 2 and missing_paths:
    others = [l for l in body if l.strip() and not any(p in l for p in missing_paths)]
    done = "検索自体は実行済みで、他のパスの結果は有効です。" if others else ""
    print(f"存在しないパスを検索対象に含めています: {', '.join(missing_paths[:3])}。{done}")
elif any(re.match(r"^[\w./-]+: (?:cannot \w+ )?.+: Permission denied$", l.strip()) for l in body):
    print("権限エラー。対象パスの所有者と権限を ls -la で確認してください (sudo や chmod は対象を確かめてから)。")
elif missing_paths:
    print(f"ファイル/ディレクトリが存在しません: {', '.join(missing_paths[:3])}。ls -la で親ディレクトリを確認してください。")
elif any(re.search(r"ENOSPC|No space left on device", l) for l in body):
    print("ディスク容量不足。不要ファイルを削除してください: docker system prune, npm cache clean --force")
elif any(re.search(r"ECONNREFUSED|Connection refused", l) for l in body):
    print("接続拒否。サービスが起動しているか確認: lsof -i :<port>, docker ps")
elif any(re.search(r"(?:Connection|Operation|Read|connect\(\)).{0,40}timed out|ETIMEDOUT", l, re.I) for l in body):
    print("ネットワークのタイムアウト。接続先と経路を確認するか、タイムアウト値を増やしてください。")
PY
)"
    if [[ -n "$GUIDANCE" ]]; then
      :
    elif echo "$CMD" | grep -qE '^(npm|pnpm|yarn)'; then
      GUIDANCE="パッケージマネージャエラー。lockfile削除と再インストールを試してください: rm -rf node_modules && npm install"
    elif echo "$CMD" | grep -qE '^pip'; then
      GUIDANCE="Pythonパッケージエラー。venvが有効か確認: which python3, pip install --upgrade pip"
    elif echo "$CMD" | grep -qE '^(docker|docker-compose)'; then
      GUIDANCE="Dockerエラー。Docker Desktopが起動しているか確認。--platform linux/amd64 が必要な場合あり(Apple Silicon)。"
    fi
    ;;
  Edit)
    if echo "$ERROR_MSG" | grep -qi "old_string.*not found\|not unique"; then
      GUIDANCE="Edit失敗: old_stringが一致しません。Readツールでファイルの現在の内容を再確認してから、正確なold_stringでリトライしてください。"
    fi
    ;;
  Write)
    if echo "$ERROR_MSG" | grep -qi "must read.*first\|did not read"; then
      GUIDANCE="Write失敗: ファイルを先にReadする必要があります。Read → Write の順序を守ってください。"
    fi
    ;;
  Grep)
    if echo "$ERROR_MSG" | grep -qi "regex.*error\|invalid.*pattern"; then
      GUIDANCE="Grep正規表現エラー。特殊文字をエスケープしてください。ripgrep構文: {} は \\{\\} に。"
    fi
    ;;
  WebFetch|WebSearch)
    if echo "$ERROR_MSG" | grep -qi "redirect"; then
      GUIDANCE="リダイレクト検出。リダイレクト先URLで再試行してください。"
    elif echo "$ERROR_MSG" | grep -qi "403\|forbidden\|unauthorized"; then
      GUIDANCE="アクセス拒否。認証が必要なURLです。gh CLI や専用MCPツールを使用してください。"
    fi
    ;;
esac

# If no specific guidance matched, provide generic guidance
if [[ -z "$GUIDANCE" ]]; then
  # Only provide generic guidance for repeated failures (avoid noise)
  exit 0
fi

if declare -F aidd_ledger_append >/dev/null 2>&1; then
  aidd_ledger_append "tool-failure-recovery" "measure" "allow" "tool=${TOOL_NAME}" "recovery-guidance"
fi

# Output additionalContext via hookSpecificOutput
# Ref: PostToolUseFailure can inject additionalContext on exit 0
if command -v jq &>/dev/null; then
  jq -n --arg ctx "[recovery-guide] ${GUIDANCE}" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":$ctx}}'
else
  # Fallback: sanitize for JSON
  _safe=$(echo "$GUIDANCE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat <<RECOVERY_JSON
{"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":"[recovery-guide] ${_safe}"}}
RECOVERY_JSON
fi
exit 0
