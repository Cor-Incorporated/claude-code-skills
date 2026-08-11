#!/usr/bin/env bash
# 4エージェント横断: 破壊形 15 + 正常形 3 を各ツールの強制点入力契約で測る（計測器・Issue #27 凍結対象外）
#
# 入力契約:
#   Claude Code : git-push-guard.sh + protect-branches.sh 合成（settings PreToolUse と同じ）
#                 stdin JSON tool_input.command → exit≠0 = block
#   Cursor      : ~/.cursor/hooks/git-guard.sh  stdin {"command":..} → permission deny
#   Codex CLI   : codex execpolicy check --rules default.rules <tokens...> → forbidden
#   OpenCode    : 本スクリプトは permission 層を静的に要約（plugin は T6 で別判定）
#
# CI NOTICE: 受領側パスが無ければ全 SKIP。緑を「均衡済み」と読まないこと。
set -uo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

CC_GUARD="${HOME}/.claude/hooks/git-push-guard.sh"
CC_PROTECT="${HOME}/.claude/hooks/protect-branches.sh"
CU_HOOK="${HOME}/.cursor/hooks/git-guard.sh"
CX_RULES="${HOME}/.codex/rules/default.rules"

declare -a BAD=(
  'git push origin --mirror'
  'git push origin "--mirror"'
  'git push --mirror origin'
  'git push origin +main'
  'git push origin +main:main'
  'git push origin +develop'
  'git push --force origin main'
  'git push -f origin main'
  'git push --force-with-lease origin main'
  'git push --all --force origin'
  'git push origin --delete main'
  'git push origin :main'
  'git -c foo=bar push origin --mirror'
  'git push origin main'
  'git push -u origin develop'
)
declare -a GOOD=(
  'git push origin feat/x'
  'git push -u origin docs/y'
  'git status'
)

have_cc=0; have_cu=0; have_cx=0
[[ -x "$CC_GUARD" && -x "$CC_PROTECT" ]] && have_cc=1
[[ -x "$CU_HOOK" ]] && have_cu=1
[[ -f "$CX_RULES" ]] && command -v codex >/dev/null 2>&1 && have_cx=1

if [[ "$have_cc$have_cu$have_cx" == "000" ]]; then
  echo "NOTICE: 強制点ファイルが 1 つも無い（CI 等）。本結果は横断均衡の証明ではない。全 SKIP。"
  exit 0
fi

cc_block() {
  local cmd="$1" p rc1=0 rc2=0
  p=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  printf '%s' "$p" | bash "$CC_GUARD" >/dev/null 2>&1 || rc1=$?
  printf '%s' "$p" | bash "$CC_PROTECT" >/dev/null 2>&1 || rc2=$?
  [[ "$rc1" -ne 0 || "$rc2" -ne 0 ]]
}
cu_block() {
  local cmd="$1" out p
  p=$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$cmd")
  out=$(printf '%s' "$p" | bash "$CU_HOOK" 2>/dev/null || true)
  printf '%s' "$out" | grep -qE '"permission"[[:space:]]*:[[:space:]]*"deny"'
}
cx_block() {
  local cmd="$1" out
  # Tokenize like a shell (strip quotes) — unquoted $cmd keeps quote chars as part of tokens
  # and would falsely report holes for forms like: git push origin "--mirror"
  out=$(python3 -c '
import subprocess, shlex, sys
cmd, rules = sys.argv[1], sys.argv[2]
tokens = shlex.split(cmd)
r = subprocess.run(["codex","execpolicy","check","--rules",rules,*tokens], capture_output=True, text=True)
print(r.stdout + r.stderr)
' "$cmd" "$CX_RULES" 2>/dev/null || true)
  printf '%s' "$out" | grep -qi 'forbidden'
}

printf '%-40s %-10s %-10s %-10s\n' "コマンド" "ClaudeCode" "Cursor" "Codex"
printf '%s\n' "--------------------------------------------------------------------------------"
cc_f=0; cu_f=0; cx_f=0
for c in "${BAD[@]}"; do
  if [[ "$have_cc" -eq 1 ]]; then
    cc_block "$c" && a="BLOCK" || { a="**通過**"; cc_f=$((cc_f+1)); }
  else a="SKIP"; fi
  if [[ "$have_cu" -eq 1 ]]; then
    cu_block "$c" && b="BLOCK" || { b="**通過**"; cu_f=$((cu_f+1)); }
  else b="SKIP"; fi
  if [[ "$have_cx" -eq 1 ]]; then
    cx_block "$c" && d="BLOCK" || { d="**通過**"; cx_f=$((cx_f+1)); }
  else d="SKIP"; fi
  printf '%-40s %-10s %-10s %-10s\n' "$c" "$a" "$b" "$d"
done
echo ""
printf '%-40s %-10s %-10s %-10s\n' "--- 正常形 ---" "" "" ""
cc_p=0; cu_p=0; cx_p=0
for c in "${GOOD[@]}"; do
  if [[ "$have_cc" -eq 1 ]]; then
    cc_block "$c" && { a="**偽陽性**"; cc_p=$((cc_p+1)); } || a="通過"
  else a="SKIP"; fi
  if [[ "$have_cu" -eq 1 ]]; then
    cu_block "$c" && { b="**偽陽性**"; cu_p=$((cu_p+1)); } || b="通過"
  else b="SKIP"; fi
  if [[ "$have_cx" -eq 1 ]]; then
    cx_block "$c" && { d="**偽陽性**"; cx_p=$((cx_p+1)); } || d="通過"
  else d="SKIP"; fi
  printf '%-40s %-10s %-10s %-10s\n' "$c" "$a" "$b" "$d"
done
echo ""
echo "破壊形 ${#BAD[@]} 件中の通過（穴）: ClaudeCode=$cc_f  Cursor=$cu_f  Codex=$cx_f"
echo "正常形 ${#GOOD[@]} 件中の偽陽性:  ClaudeCode=$cc_p  Cursor=$cu_p  Codex=$cx_p"
echo "OpenCode: opencode.jsonc permission は git push*=ask / --force*・-f=deny（本表外・T6 参照）"
# 非ゼロ穴は情報として返す（CI で赤にしない — 計測器）。ローカル均衡監査は人間が読む。
exit 0
