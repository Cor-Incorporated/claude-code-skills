#!/usr/bin/env bash
# 4エージェント横断: 破壊形 15 + 正常形 3 を各ツールの強制点入力契約で測る
#
# 2026-09-03 まで純粋な計測器（Issue #27 凍結対象外）だったが、**門にした**。
# 測るだけで exit code に反映しないと、正しい測定値が 20 日間読まれずに残る
# ことが実際に起きた（末尾の「門」節に経緯）。穴・偽陽性・foreign PR 不一致の
# いずれかが 0 でなければ exit 1 になる。
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
export AIDD_LEDGER_SOURCE=test

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX_HOME="$(mktemp -d)"
trap 'rm -rf "$MATRIX_HOME"' EXIT
mkdir -p "$MATRIX_HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$MATRIX_HOME/.claude/hooks/lib/aidd-ledger.sh"

CC_GUARD="${CC_GUARD:-${HOME}/.claude/hooks/git-push-guard.sh}"
CC_PROTECT="${CC_PROTECT:-${HOME}/.claude/hooks/protect-branches.sh}"
CU_HOOK="${CU_HOOK:-${HOME}/.cursor/hooks/git-guard.sh}"
CX_RULES="${CX_RULES:-${HOME}/.codex/rules/default.rules}"

# 強制点のパスを絶対化する。この装置は fixture へ `cd` してからガードを起動する
# ので、相対パスのままだと `bash <path>` が起動に失敗して **127** を返す。127 を
# 「rc≠0 = BLOCK」と読むと、**壊れたハーネスが「ちゃんと止めている」表を出す。**
# 本日この形の誤りを実際に踏んだので、入口で潰しておく。
_abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd)" "$1" ;; esac; }
CC_GUARD="$(_abspath "$CC_GUARD")"
CC_PROTECT="$(_abspath "$CC_PROTECT")"
CU_HOOK="$(_abspath "$CU_HOOK")"
CX_RULES="$(_abspath "$CX_RULES")"

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
  printf '%s' "$p" | (cd "$MATRIX_FIX" && env HOME="$MATRIX_HOME" AIDD_LEDGER_SOURCE=test bash "$CC_GUARD") >/dev/null 2>&1 || rc1=$?
  printf '%s' "$p" | (cd "$MATRIX_FIX" && env HOME="$MATRIX_HOME" AIDD_LEDGER_SOURCE=test bash "$CC_PROTECT") >/dev/null 2>&1 || rc2=$?
  [[ "$rc1" -ne 0 || "$rc2" -ne 0 ]]
}
cu_block() {
  local cmd="$1" out p
  p=$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$cmd")
  out=$(printf '%s' "$p" | (cd "$MATRIX_FIX" && env HOME="$MATRIX_HOME" AIDD_LEDGER_SOURCE=test bash "$CU_HOOK") 2>/dev/null || true)
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

# --- 測定文脈を固定する（2026-09-03）---------------------------------------
# 各ガードは `git rev-parse --abbrev-ref HEAD` / `git branch --show-current` で
# **周囲のブランチ**を読む。つまりこの装置の測定値は、実行者がどのブランチを
# チェックアウトしているかで変わっていた。
#
# 実害: 門を足した直後、非保護ブランチ上で走らせたら **修正前のガードでも
# 偽陽性 0 で緑になった。** 保護ブランチ上でのみ Cursor=2 が出る。
# つまり「門はあるが、走らせる場所によっては欠陥を見ない」状態だった。
# 測定値が環境で変わる装置に門を付けても、それは門ではない。
#
# そこで fixture リポジトリを作り、**両方の文脈で測って合算**する。
#   保護ブランチ上   … 過剰ブロック（GOOD 側の偽陽性）が最も出やすい
#   非保護ブランチ上 … 破壊形の穴（BAD 側）が最も出やすい。
#                      保護ブランチ上は「全部 deny」で穴が隠れてしまう
# どちらか一方だけでは片側の欠陥を見落とす。
MATRIX_FIX="$MATRIX_HOME/fixture"
git init -q "$MATRIX_FIX"
git -C "$MATRIX_FIX" symbolic-ref HEAD refs/heads/develop
git -C "$MATRIX_FIX" -c user.email=test@example.invalid -c user.name=test \
  commit -q --allow-empty -m init
git -C "$MATRIX_FIX" branch feat/matrix
# foreign PR 判定は origin の owner を読むので、実 origin を複製しておく。
# 取得元は **ambient cwd ではなく $ROOT**（この装置が属するリポジトリ）。
# ambient から取ると、リポ外や origin 無しの場所から起動したときに owner が
# 空になり、different-owner が ASK ではなく ALLOW に見えて落ちる。
# 起動位置を暗黙の入力にしない、というのがこのファイル全体の方針である。
_origin_for_fixture=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
[[ -n "$_origin_for_fixture" ]] \
  && git -C "$MATRIX_FIX" remote add origin "$_origin_for_fixture"

cc_f=0; cu_f=0; cx_f=0
cc_p=0; cu_p=0; cx_p=0

for MATRIX_BRANCH in develop feat/matrix; do
  git -C "$MATRIX_FIX" checkout -q "$MATRIX_BRANCH"
  _seen=$(cd "$MATRIX_FIX" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ "$_seen" != "$MATRIX_BRANCH" ]]; then
    echo "FATAL: fixture のブランチ切替に失敗 (要求=$MATRIX_BRANCH 実際=$_seen)" >&2
    exit 1
  fi
  echo ""
  echo "=== 測定文脈: $MATRIX_BRANCH ($([[ "$MATRIX_BRANCH" == develop ]] && echo 保護 || echo 非保護)) ==="
  printf '%-40s %-10s %-10s %-10s\n' "コマンド" "ClaudeCode" "Cursor" "Codex"
  printf '%s\n' "--------------------------------------------------------------------------------"
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
done
echo ""
echo ""
echo "破壊形 ${#BAD[@]} 件中の通過（穴）: ClaudeCode=$cc_f  Cursor=$cu_f  Codex=$cx_f"
echo "正常形 ${#GOOD[@]} 件中の偽陽性:  ClaudeCode=$cc_p  Cursor=$cu_p  Codex=$cx_p"
echo "OpenCode: opencode.jsonc permission は git push*=ask / --force*・-f=deny（本表外・T6 参照）"

# Phase 15 T15-1: explicit foreign repository PR target must ask, never block.
# Axes: --repo same/different/none x gh pr create/merge x quoted/unquoted.
cc_pr_state() {
  local cmd="$1" p out rc=0
  p=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  out=$(printf '%s' "$p" | (cd "$MATRIX_FIX" && env HOME="$MATRIX_HOME" AIDD_LEDGER_SOURCE=test bash "$CC_PROTECT") 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "BLOCK"
  elif printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'; then
    echo "ASK"
  else
    echo "ALLOW"
  fi
}
cu_pr_state() {
  local cmd="$1" p out
  p=$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$cmd")
  out=$(printf '%s' "$p" | (cd "$MATRIX_FIX" && env HOME="$MATRIX_HOME" AIDD_LEDGER_SOURCE=test bash "$CU_HOOK") 2>/dev/null || true)
  if printf '%s' "$out" | grep -qE '"permission"[[:space:]]*:[[:space:]]*"ask"'; then
    echo "ASK"
  elif printf '%s' "$out" | grep -qE '"permission"[[:space:]]*:[[:space:]]*"deny"'; then
    echo "BLOCK"
  else
    echo "ALLOW"
  fi
}

# foreign PR 節も fixture の中で測る。ambient cwd で測っていたため、origin remote
# の無いディレクトリ（git archive 展開先など）から走らせると owner が空になり、
# different-owner が ASK ではなく ALLOW に見えて mismatches=8 で落ちていた。
# 装置の結論が「どこから起動したか」で変わってはならない。
# fixture のブランチも固定する（非保護側）。ここは push 判定ではないが、
# 起動位置と同じく暗黙の入力にしない。
git -C "$MATRIX_FIX" checkout -q feat/matrix
origin_url=$(git -C "$MATRIX_FIX" remote get-url origin 2>/dev/null || true)
origin_slug=$(printf '%s' "$origin_url" | sed -E 's#^git@[^:]+:##; s#^ssh://git@[^/]+/##; s#^https?://[^/]+/##; s#\.git$##')
origin_owner="${origin_slug%%/*}"
same_repo="${origin_owner}/phase15-self"
foreign_repo="anomalyco/opencode"
if [[ "$(printf '%s' "$origin_owner" | tr '[:upper:]' '[:lower:]')" == "anomalyco" ]]; then
  foreign_repo="Cor-Incorporated/aidd-governance"
fi

echo ""
echo "--- foreign PR ask matrix (repo axis x operation x quote axis) ---"
printf '%-12s %-8s %-10s %-12s %-10s %-10s\n' "repo" "op" "quote" "expected" "Claude" "Cursor"
pr_fail=0
for repo_axis in same different none; do
  case "$repo_axis" in
    same) repo_value="$same_repo"; expected="ALLOW" ;;
    different) repo_value="$foreign_repo"; expected="ASK" ;;
    none) repo_value=""; expected="ALLOW" ;;
  esac
  for op in create merge; do
    for quote_axis in unquoted quoted; do
      if [[ "$op" == "create" ]]; then
        if [[ "$quote_axis" == "quoted" ]]; then
          cmd='"gh" "pr" "create" --title "phase15" --body "test"'
          [[ -n "$repo_value" ]] && cmd="$cmd \"--repo\" \"$repo_value\""
        else
          cmd='gh pr create --title phase15 --body test'
          [[ -n "$repo_value" ]] && cmd="$cmd --repo $repo_value"
        fi
      else
        if [[ "$quote_axis" == "quoted" ]]; then
          cmd='"gh" "pr" "merge" "1" "--merge"'
          [[ -n "$repo_value" ]] && cmd="$cmd \"--repo\" \"$repo_value\""
        else
          cmd='gh pr merge 1 --merge'
          [[ -n "$repo_value" ]] && cmd="$cmd --repo $repo_value"
        fi
      fi
      if [[ "$have_cc" -eq 1 ]]; then cc_actual=$(cc_pr_state "$cmd"); else cc_actual="SKIP"; fi
      if [[ "$have_cu" -eq 1 ]]; then cu_actual=$(cu_pr_state "$cmd"); else cu_actual="SKIP"; fi
      [[ "$cc_actual" == "SKIP" || "$cc_actual" == "$expected" ]] || pr_fail=$((pr_fail + 1))
      [[ "$cu_actual" == "SKIP" || "$cu_actual" == "$expected" ]] || pr_fail=$((pr_fail + 1))
      printf '%-12s %-8s %-10s %-12s %-10s %-10s\n' "$repo_axis" "$op" "$quote_axis" "$expected" "$cc_actual" "$cu_actual"
    done
  done
done
echo "foreign PR matrix mismatches=$pr_fail (same/none false positives and different-owner misses combined)"

# origin owner が決められないと different-owner が構成できず、ASK ではなく ALLOW に
# 見えて mismatches が積み上がる。**これは強制点の欠陥ではなくハーネスの設定失敗
# である。** 同じ数字を「ガードが緩んだ」と読ませてはならない（本日、起動失敗の
# 127 を BLOCK と読み違えたのと同じ型の誤り）。
# 「測れなかった」は緑にはしない。ラベルを分けて落とす。
foreign_unmeasurable=0
if [[ -z "$origin_owner" ]]; then
  foreign_unmeasurable=1
  echo "NOTICE: origin owner を決定できず foreign PR 節は測定不能（$ROOT に origin remote が無い）。" >&2
  echo "        上の mismatches は強制点の欠陥ではなくハーネス側の未設定である。" >&2
fi

# =============================================================================
# 門（2026-09-03 追加）
# =============================================================================
# ここは長らく `[[ "$pr_fail" -eq 0 ]]` **だけ**を見ていた。つまり foreign PR
# マトリクスの不一致しか exit code に反映されず、**破壊形の穴（BAD）も
# 正常形の偽陽性（GOOD）も、画面に出すだけで通していた。**
#
# 実害が出た。2026-08-13 以降、この装置は保護ブランチ上で
#
#     正常形 3 件中の偽陽性:  ClaudeCode=0  Cursor=2  Codex=0
#
# を **正しく測って画面に出しながら exit 0 で通り続けた。** 誰も読まなかった。
# その間 develop の CI は別件（test-cursor-git-guard-segments.sh の環境依存）で
# 38 run 連続赤（2026-08-13T19:29 以降）で、この表は赤の海に埋もれていた。
# **測っているのに門にしていない装置は、測っていないのと同じである。**
#
# 期待値は「現在値」ではなく 0 を書く。`Cursor=2` のような現在値を焼き込むと
# 3 件目が入ったときに通ってしまう（門ではなく現状追認になる）。
#
# SKIP の扱い: 受領側パスが無いツールはカウンタが 0 のまま増えないので、門は
# 素通りする。これは意図である。冒頭の NOTICE のとおり **全 SKIP の緑を
# 「均衡済み」と読んではならない。** 門は「測れた範囲で 0」しか主張しない。
gate_fail=0
gate_check() { # gate_check <ラベル> <実測値>
  if [[ "$2" -ne 0 ]]; then
    printf 'GATE-FAIL: %s=%s (期待 0)\n' "$1" "$2" >&2
    gate_fail=1
  fi
}
echo ""
echo "--- 門: 穴 0 / 偽陽性 0 / foreign PR mismatches 0 ---"
gate_check "hole/ClaudeCode"          "$cc_f"
gate_check "hole/Cursor"              "$cu_f"
gate_check "hole/Codex"               "$cx_f"
gate_check "falsepositive/ClaudeCode" "$cc_p"
gate_check "falsepositive/Cursor"     "$cu_p"
gate_check "falsepositive/Codex"      "$cx_p"
if [[ "$foreign_unmeasurable" -eq 1 ]]; then
  # 測定不能も 0 にはしない。ただし強制点の欠陥とは別のラベルで落とす。
  gate_check "foreignPR/UNMEASURABLE(ハーネス未設定)" 1
else
  gate_check "foreignPR/mismatches"   "$pr_fail"
fi
if [[ "$gate_fail" -eq 0 ]]; then
  echo "GATE-PASS: 測れた範囲で 穴 0 / 偽陽性 0 / foreign PR mismatches 0"
else
  echo "GATE-FAIL: 4 強制点の横断均衡が崩れている（上の GATE-FAIL 行を参照）。" >&2
fi
exit "$gate_fail"
