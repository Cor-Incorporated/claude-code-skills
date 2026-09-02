#!/bin/bash
# Check 0a2 (refspec force `+<ref>`) — 判定範囲の固定
#
# 発端（2026-09-02、同日 5 回発火）:
#   Check 0a2 は 2 つの述語をコマンド文字列**全体**に独立に当てていた。
#
#     grep -qE "$_GIT_PUSH_RE"  &&  grep -qE '[[:space:]:]\+[A-Za-z0-9_./-]'
#
#   `git push` と `+18` が文字列の別の場所にあるだけで一致するため、
#   **push ガードの話をしているコミットメッセージが block された。**
#   運用者は `git commit -F <file>` で迂回した。
#   迂回されるガードは何も守っていない（aidd-governance#100 C-3）。
#
# 軸:
#   F1  陽性対照 — 真の破壊形は block のまま（緩めていないことの証明）
#   F2  陰性対照 — 同日の実際の事故入力 5 種が allow になる
#   F3  片側変異 — 旧・全文字列照合へ戻すと事故入力が再び block する
#       （= この修正が効いていることの証明。通らなければ F2 は別要因）
#
# 既存の F1 マトリクス（tests/test-destructive-push-forms.sh 62 ケース）と
# プロセス置換スイート（28 ケース）は非回帰として別途実行すること。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/protect-branches.sh"
PASS=0; FAIL=0

# このスイートは意図的に block を起こす。未設定だと合成発火が防御台帳へ
# source=real で積まれ、「このガードは実際に何回効いたか」という指標を汚す。
# aidd_ledger_append は書き込み先を $HOME 固定で持つため、パスは変えられない。
export AIDD_LEDGER_SOURCE=test

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # 改行・タブも要る。既存スイートの json_escape はここが無く、複数行の入力
  # （heredoc 本文など）で不正な JSON になり、hook が block ではなく
  # エラー終了する。rc だけ見ていると「止まった」と誤読する。
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# run_case <hook> <name> <expect> <cmd>
run_case() {
  local hook="$1" name="$2" expect="$3" cmd="$4" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
    | bash "$hook" >/dev/null 2>&1 || rc=$?
  local ok=0
  if [ "$expect" = "block" ]; then [ "$rc" -ne 0 ] && ok=1; else [ "$rc" -eq 0 ] && ok=1; fi
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $name (rc=$rc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expect=$expect rc=$rc) :: $cmd"; FAIL=$((FAIL + 1))
  fi
}
test_case() { run_case "$HOOK" "$@"; }

# `+` はここで組み立てる。テストファイル自身が事故入力の形を含むと、
# このファイルを編集するコマンドがガードに引っかかって編集できなくなる
# （実際に本修正の調査中、検査用ハーネスがガードに block された）。
P='+'

echo "=== F1 陽性対照: 真の破壊形は block のまま ==="
test_case "refspec force to main"            block "git push origin ${P}main"
test_case "refspec force full ref"           block "git push origin ${P}refs/heads/main"
test_case "refspec force src:dst"            block "git push origin ${P}main:main"
test_case "refspec force develop"            block "git push origin ${P}develop"
test_case "refspec force quoted"             block "git push origin \"${P}main\""
test_case "refspec force on dst side"        block "git push origin HEAD:${P}main"
test_case "refspec force after git -c"       block "git -c core.pager=cat push origin ${P}main"
test_case "refspec force chained after &&"   block "git status && git push origin ${P}main"
test_case "explicit -f to main"              block 'git push -f origin main'
test_case "explicit --force to main"         block 'git push --force origin main'
test_case "--force-with-lease to main"       block 'git push --force-with-lease origin main'
test_case "direct push to main"              block 'git push origin main'

# **空白の有無で結果が変わることが 2026-09-02 の退行の本体だった。**
# 第一版は `(git`（空白なし）だけを陽性対照に置いていたため、括弧の後に空白を
# 入れる通常の書き方が block から allow へ落ちたことに気づけなかった。
# 7 形中 6 形が素通しになっていた。原因は、括弧・波括弧を剥がした残りが
# 空文字トークンになり、それを飛ばさずに判定へ落としていたこと。
# 両形を必ず対にして並べること。
echo "--- 群化・入れ子（空白の有無を必ず対にする） ---"
test_case "subshell, no space"               block "(git push origin ${P}main)"
test_case "subshell, space after paren"      block "( git push origin ${P}main)"
test_case "subshell, spaces both sides"      block "( git push origin ${P}main )"
test_case "brace group"                      block "{ git push origin ${P}main; }"
test_case "bash -c"                          block "bash -c 'git push origin ${P}main'"
test_case "after cd + semicolon"             block "cd /tmp; ( git push origin ${P}main )"
test_case "after true &&"                    block "true && ( git push origin ${P}main )"

# インタプリタ経由。第二版はここを 6 形すべて素通しにした。原因は stage 2 の
# `git` 判定がトークン等価で、`os.system(git` の中の git を拾えなかったこと。
#
# **インタプリタ名を列挙して塞いではならない。列挙は必ず漏れる。**
# `ruby` と `deno` は hook のどのリストにも入っていない。この 2 件が block で
# あることが、判定が列挙ではなくセグメントの中身に基づいている証拠になる。
# 列挙で通す実装に戻したら、まずこの 2 件が red になる。
echo "--- インタプリタ経由（列挙に頼っていないことの対照を含む） ---"
FORCE="git push origin ${P}main"
test_case "python3 -c, double quotes"        block "python3 -c \"import os; os.system('${FORCE}')\""
test_case "python3 -c, single quotes"        block "python3 -c 'import os; os.system(\"${FORCE}\")'"
test_case "python3 -c, __import__"           block "python3 -c \"__import__('os').system('${FORCE}')\""
test_case "python3 - heredoc (本文はコード)"  block "python3 - <<'PY'
import os
os.system(\"${FORCE}\")
PY"
test_case "perl -e"                          block "perl -e 'system(\"${FORCE}\")'"
test_case "node -e"                          block "node -e \"require('child_process').execSync('${FORCE}')\""
test_case "ruby -e (どのリストにも無い)"       block "ruby -e 'system(\"${FORCE}\")'"
test_case "deno eval (どのリストにも無い)"     block "deno eval \"Deno.run({cmd:['${FORCE}']})\""

echo ""
echo "=== F2 陰性対照: 2026-09-02 の実際の事故入力 ==="
# (1) コミットメッセージが push ガードの話をしている
test_case "commit msg mentions push guard"   allow "git commit -m \"fix: git push guard misread ${P}18\""
test_case "commit msg cites issue numbers"   allow "git commit -m \"fix(#195): git push guard ${P}195 誤検知\""
# (2) errexit 解除表記
test_case "commit msg with set +e"           allow "git commit -m \"test: set ${P}e を外して rc を拾う\""
# (3) diff hunk ヘッダ（テスト検体・レビュー引用）
test_case "commit msg with diff hunk header" allow "git commit -m \"chore: @@ -221,199 ${P}221,199 を整理\""
# (4) grep パターンに git push を含む
test_case "grep for push pattern"            allow "grep -n 'git push .*${P}main' hooks/protect-branches.sh"
# (5) heredoc 本文に記述
test_case "heredoc documenting +ref"         allow "cat <<EOF > note.md
git push origin ${P}main
EOF"
test_case "heredoc, non-protected branch"    allow "cat <<EOF > note.md
git push origin ${P}feat/x
EOF"

echo ""
echo "=== 既知の残存（別ルールの管轄。本 PR の対象外） ==="
# Check 0a2 は heredoc 本文で発火しなくなったが、保護ブランチ force push 検査
# （is_force_push + mentions_protected_ref）は設計上コマンド文字列全体を見る。
# プロセス置換や連結に隠した force push を拾うための意図的な位置非依存であり、
# tests/test-push-guard-process-substitution-bypass.sh 28 ケースが支えている。
# そのため `--force` と保護ブランチ名を同時に含む heredoc は今も block する。
# 同じ「表面形 vs 構造」の欠陥クラスだが、緩めるには別途 28 ケース側の
# 再設計が要るので本 PR では触らない。現状を記録として固定する。
test_case "heredoc with --force + main (別ルール)" block "cat <<EOF > note.md
git push --force origin main
EOF"

echo ""
echo "=== 除外が壊れていないことの対照（連結の反対側） ==="
test_case "git log && echo"                  allow "git log --oneline -1 && echo done"
test_case "commit msg quoting the form"      allow "git commit -m 'ref: git push origin ${P}main は禁止' && git status"
test_case "feature push && echo"             allow "git push origin feat/x && echo pushed"
# データ文脈の heredoc は本文を落とす（cat はファイルへ書くだけ）。
# python3 - <<PY は本文をインタプリタが実行するので落とさない（上の陽性対照）。
test_case "cat heredoc は本文がデータ"        allow "cat <<'EOF' > /tmp/note.md
git push origin ${P}main
EOF"

echo ""
echo "=== 既存の偽陽性対照（非回帰） ==="
test_case "feature branch push"              allow 'git push origin feat/x'
test_case "branch name containing plus"      allow "git push origin feat/a${P}b"
test_case "push -u to feature branch"        allow 'git push -u origin docs/y'
test_case "HEAD:feat/x refspec"              allow 'git push origin HEAD:feat/x'
test_case "git fetch"                        allow 'git fetch origin'
test_case "git log"                          allow 'git log --oneline -5'

echo ""
echo "=== F3 片側変異: 旧・全文字列照合へ戻すと事故入力が再び block する ==="
MUT=$(mktemp); trap 'rm -f "$MUT"' EXIT
# has_refspec_force の中身だけを旧実装（2 述語を全体に独立照合）へ差し替える。
python3 - "$HOOK" "$MUT" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("has_refspec_force() {")
end = src.index("\n}\n", start) + len("\n}\n")
legacy = (
    "has_refspec_force() {\n"
    "  echo \"$1\" | grep -qE \"$_GIT_PUSH_RE\" && "
    "echo \"$1\" | grep -qE '[[:space:]:]\\+[A-Za-z0-9_./-]'\n"
    "}\n"
)
open(sys.argv[2], "w", encoding="utf-8").write(src[:start] + legacy + src[end:])
PY
if bash -n "$MUT" 2>/dev/null; then
  echo "  PASS: 変異版が構文として成立している"; PASS=$((PASS + 1))
else
  echo "  FAIL: 変異版の生成に失敗した（この節の結果は無意味）"; FAIL=$((FAIL + 1))
fi
run_case "$MUT" "変異版: 事故入力が block へ戻る" block \
  "git commit -m \"fix: git push guard misread ${P}18\""
run_case "$MUT" "変異版: 陽性対照は変わらず block"  block "git push origin ${P}main"
run_case "$MUT" "変異版: 通常 push は変わらず allow" allow 'git push origin feat/x'

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
