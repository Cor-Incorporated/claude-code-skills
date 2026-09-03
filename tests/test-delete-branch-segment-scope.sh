#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/protect-branches.sh
# Check 1 / Check 2 (ブランチ削除) — 保護名の探索を**セグメントに閉じる**
#
# 発端（aidd-governance 再裁定 2026-09-03-hooks-surface-form、実測 15 件目）:
#   Check 1/2 の述語は全コマンド文字列に対する 1 本の正規表現だった。
#
#     git\s+branch\s+-[dD]\s+.*\b<protected>\b
#     push\s+.*--delete\s+.*\b<protected>\b
#
#   `.*` は `&&` / `;` / `|` を跨ぐので、**後続セグメント**に現れた保護名を
#   削除対象として読んだ。lane 撤収の複合コマンドが実際に誤 block された。
#
#   決め手は**順序を逆にすると通る**こと。同じ 2 セグメントで順序だけが違うのに
#   結論が変わるなら、それは構文ではなく位置を見ている。
#
#   同じファイルの Check 3b は既に `[^|;&)<>]` で区切りを除いており、
#   18 ケースで誤発火しなかった。**戦略は適用された場所では効いていた。**
#   保護名を照合する 5 箇所のうち、跨いでいたのはこの 2 つだけだった。
#
#   さらに実測で分かったこと: **`git` と `branch` の隣接を要求していたため**
#     git -C <dir> branch -D <protected>
#     git -c foo=bar branch -D <protected>
#     git --no-replace-objects branch -D <protected>
#   が 3 形とも**素通りしていた**。git-push-guard.sh は削除を見ないので
#   多層防御も無い。誤検知（止めすぎ）と見逃し（止め損ね）が同居していた。
#   緩めるだけでは足りず、隣接要求を外すことが同じ修正に含まれている。
#
# 軸:
#   F1  陽性対照 — 実削除は block のまま。上記 3 形は**新たに** block になる
#   F2  陰性対照 — 2026-09-03 の実際の誤検知入力が allow になる
#   F3  片側変異 — セグメント化 / コメント除去 / グローバルオプション許容 を
#                  1 つずつ壊すと、対応するケースだけが元の誤りへ戻る
#
# 実行:  bash tests/test-delete-branch-segment-scope.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/protect-branches.sh"
PASS=0; FAIL=0

# 合成発火を防御台帳へ source=real で積まない（この指標は「実際に何回効いたか」）。
# 2026-09-03 にこれを付け忘れて実台帳へ 16 行入れた事故がある。
export AIDD_LEDGER_SOURCE=test

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 保護ブランチ上 / 非保護ブランチ上の probe リポジトリ。
# 両方で測るのは、判定が current branch に依存していないことを示すため。
# （ccs develop が 20 日 red だった原因が current branch 依存だった。）
for pair in "protected:main" "feature:feat/x"; do
  name="${pair%%:*}"; br="${pair##*:}"
  git init -q "$WORK/$name"
  git -C "$WORK/$name" symbolic-ref HEAD "refs/heads/$br"
done
[ "$(git -C "$WORK/protected" branch --show-current)" = "main" ] \
  || { echo "FATAL: probe リポジトリの current branch が main でない"; exit 1; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# run_case <hook> <repo> <name> <expect> <cmd>
run_case() {
  local hook="$1" repo="$2" name="$3" expect="$4" cmd="$5" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
    | (cd "$WORK/$repo" && bash "$hook" >/dev/null 2>&1) || rc=$?
  local ok=0
  if [ "$expect" = "block" ]; then [ "$rc" -ne 0 ] && ok=1; else [ "$rc" -eq 0 ] && ok=1; fi
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $name (rc=$rc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expect=$expect rc=$rc) :: $cmd"; FAIL=$((FAIL + 1))
  fi
}
# 既定は保護ブランチ上の probe リポジトリ（保守側）
test_case() { run_case "$HOOK" protected "$@"; }
# 両リポジトリで測る（current branch 依存の検出）
both_case() {
  run_case "$HOOK" protected "$1 [on main]" "$2" "$3"
  run_case "$HOOK" feature   "$1 [on feat]" "$2" "$3"
}

# 語はここで組み立てる。素の形をこのファイルに直接書くと、**このファイルを扱う
# コマンド自身が（未更新の）ガードに掛かって編集できなくなる。**
# test-delete-branch-flag-scope.sh:91-94 と同じ理由。2026-09-03 に監督が
# heredoc でこのファイルを書こうとして 3 回 block されている。
BD="branch -""D"          # ローカル削除
PD="--dele""te"           # リモート削除
P1="deve""lop"            # 保護名
P2="ma""in"               # 保護名（develop 固有でないことの対照）

echo "=== F1 陽性対照: 実削除は block のまま ==="
test_case "ローカル削除"                block "git $BD $P1"
test_case "リモート削除"                block "git push origin $PD $P1"
test_case "コロン形"                    block "git push origin :$P1"
test_case "$P2 も同じ"                  block "git push origin $PD $P2"
test_case "セミコロンの後の削除"        block "npm test ; git $BD $P1"
test_case "プロセス置換の中の削除"      block "cat <(git push origin $PD $P1)"
test_case "削除の後ろにコメント"        block "git push origin $PD $P1 # 無害なコメント"
test_case "コメント記号を先に置く迂回"  block "echo \"#\" && git push origin $PD $P1"
test_case "引用内の # のあと実削除"     block "git commit -m \"fix #12\" && git push origin $PD $P1"
test_case "引用された # を引数に持つ"   block "git push origin $PD $P1 \"#\""

echo ""
echo "--- 隣接要求のせいで素通りしていた 3 形（修正前は allow だった見逃し）---"
test_case "-C <dir> を挟む"             block "git -C /tmp/repo $BD $P1"
test_case "-c k=v を挟む"               block "git -c foo=bar $BD $P1"
test_case "--no-replace-objects を挟む" block "git --no-replace-objects $BD $P1"
test_case "引用 # を config 値に持つ"   block "git -c core.pager=\"#\" $BD $P1"

echo ""
echo "=== F2 陰性対照: 2026-09-03 の実際の誤検知入力が allow になる ==="
both_case "連結: 削除→保護名を含む log" allow "git push origin $PD feat/x && git log origin/$P1"
both_case "連結: ローカル削除→log"      allow "git $BD feat/x && git log origin/$P1"
both_case "引用（単引用）"              allow "CMD='git push origin $PD feat/x && git log origin/$P1'"
both_case "引用（二重引用）"            allow "echo \"git $BD feat/x && git log origin/$P1\""
both_case "変数代入"                    allow "CASE=\"git push origin $PD feat/x\"; REF=\"origin/$P1\""
both_case "コメント（区切り無し）"      allow "git status  # git $BD feat/x のあと origin/$P1 を見る"
both_case "コメント（区切りあり）"      allow "git status ; # git $BD feat/x origin/$P1"
both_case "$P2 でも同じ"                allow "git push origin $PD feat/x && git log origin/$P2"

echo ""
echo "=== 非回帰: 単独セグメントと逆順は元から allow のまま ==="
test_case "worktree remove"             allow "git worktree remove .worktrees/lane/denom"
test_case "非保護ブランチの削除 単独"   allow "git $BD docs/pair18-denominator"
test_case "非保護のリモート削除 単独"   allow "git push origin $PD docs/pair18-denominator"
test_case "fetch"                       allow "git fetch origin $P1 -q"
test_case "log 単独"                    allow "git log --oneline -2 origin/$P1"
test_case "逆順: log → 削除"            allow "git log origin/$P1 && git push origin $PD feat/x"
test_case "逆順: log → ローカル削除"    allow "git log origin/$P1 && git $BD feat/x"

echo ""
echo "=== F3 片側変異: 1 つずつ壊すと対応するケースだけ元の誤りへ戻る ==="
mutate() {
  local out="$1" kind="$2"
  python3 - "$HOOK" "$out" "$kind" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
kind = sys.argv[3]

if kind == "segment":
    # セグメント化を消す: 分割せず全文字列を 1 セグメントとして扱う
    old = """  normalized=$(printf '%s' "$cmd" | tr '<>();|&' '\\n')"""
    assert src.count(old) == 1, "セグメント化の形が変わっている"
    src = src.replace(old, """  normalized="$cmd\"""")
elif kind == "comment":
    # コメント除去を消す: `#` 以降を落とさない
    old = """        segment="$prefix\""""
    assert src.count(old) == 1, "コメント除去の形が変わっている"
    src = src.replace(old, """        : "$prefix\"""")
elif kind == "globalopts":
    # グローバルオプションの許容を消す: git と branch の隣接を再び要求する
    old = '_GIT_GLOBAL_OPTS="([[:space:]]+(-[cC][[:space:]]*[^[:space:]]+|--[a-zA-Z][a-zA-Z0-9-]*(=[^[:space:]]*)?))*"'
    assert src.count(old) == 1, "_GIT_GLOBAL_OPTS の形が変わっている"
    src = src.replace(old, '_GIT_GLOBAL_OPTS=""')
else:
    raise SystemExit("unknown mutation " + kind)

open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
  bash -n "$out" 2>/dev/null
}

for kind in segment comment globalopts; do
  MUT="$WORK/mut-$kind.sh"
  if mutate "$MUT" "$kind"; then
    echo "  PASS: 変異版[$kind] が構文として成立している"; PASS=$((PASS + 1))
  else
    echo "  FAIL: 変異版[$kind] の生成に失敗（この節の結果は無意味）"; FAIL=$((FAIL + 1))
    continue
  fi
  # 統制: 変異版でも実削除は必ず block する。ここが allow なら
  # 「変異が効いた」ではなく「変異版が動いていない」である（今日 2 回踏んだ形）。
  run_case "$MUT" protected "  [$kind] 統制: 実削除は block のまま" block "git $BD $P1"
  case "$kind" in
    segment)
      run_case "$MUT" protected "  [segment] 連結が block へ戻る"      block "git push origin $PD feat/x && git log origin/$P1"
      run_case "$MUT" protected "  [segment] 引用が block へ戻る"      block "echo \"git $BD feat/x && git log origin/$P1\""
      # 逆順は**変異版でも allow**。修正前からそうだった（R1/R2）。
      # 同じ 2 セグメントで順序だけが違うのに、連結は block・逆順は allow —
      # これが「位置で見ていて構文で見ていない」ことの直接の証拠である。
      run_case "$MUT" protected "  [segment] 逆順は変異版でも allow（位置依存の証拠）" allow "git log origin/$P1 && git $BD feat/x"
      run_case "$MUT" protected "  [segment] -C 形は変わらず block"    block "git -C /tmp/repo $BD $P1"
      ;;
    comment)
      run_case "$MUT" protected "  [comment] コメントが block へ戻る"  block "git status  # git $BD feat/x のあと origin/$P1 を見る"
      run_case "$MUT" protected "  [comment] 連結は allow のまま"      allow "git push origin $PD feat/x && git log origin/$P1"
      run_case "$MUT" protected "  [comment] -C 形は変わらず block"    block "git -C /tmp/repo $BD $P1"
      ;;
    globalopts)
      run_case "$MUT" protected "  [globalopts] -C 形が allow へ戻る(見逃し)" allow "git -C /tmp/repo $BD $P1"
      run_case "$MUT" protected "  [globalopts] -c 形が allow へ戻る(見逃し)" allow "git -c foo=bar $BD $P1"
      run_case "$MUT" protected "  [globalopts] 連結は allow のまま"   allow "git push origin $PD feat/x && git log origin/$P1"
      run_case "$MUT" protected "  [globalopts] 素の削除は変わらず block" block "git $BD $P1"
      ;;
  esac
done

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
