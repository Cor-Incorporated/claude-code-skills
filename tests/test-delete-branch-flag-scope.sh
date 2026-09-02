#!/bin/bash
# Check 4 (gh pr merge の削除フラグ) — 値と位置の固定
#
# 発端（issue #358、2026-09-02 に 2 回）:
#   Check 4 の述語は 1 本の正規表現だった。
#
#     echo "$cmd" | grep -qE 'gh\s+pr\s+merge.*--delete-branch'
#
#   これは 2 つの区別ができない。
#     (1) 値   `--delete-branch=false` は **削除しない** 指定である。それを
#              前方一致で「削除しうる」と読んで block した。
#     (2) 位置 事故を報告する issue 本文を heredoc で書こうとしたら、
#              **本文に語が現れるだけで** 同じ block が出た。
#              `cat > f.md` はブランチを削除しない。
#   運用者は 2 回ともガードを迂回した（1 回目はフラグを外す、2 回目は
#   Write ツールでガードの経路を通らずに書く）。
#   迂回された発火は「よく働いているガード」と発火回数では区別できない。
#
#   さらに実測で分かったこと: **短縮形 `-d` を一度も見ていなかった。**
#   つまり否定側の誤検知と肯定側の見逃しが同居していた。緩めるだけでは
#   足りず、`-d` を塞ぐことが同じ修正に含まれていなければならない。
#
# 軸:
#   F1  陽性対照 — 削除しうる形は block のまま。`-d` 系は新たに block になる
#                  （= 誤検知を減らす修正で見逃しを増やしていないことの証明）
#   F2  陰性対照 — issue #358 の実際の事故入力が allow になる
#   F3  片側変異 — 値の判定 / heredoc の位置判定 / セグメントの位置判定 を
#                  1 つずつ壊すと、対応するケースだけが元の誤りへ戻る
#
# 判定環境は毎回作る。`gh` は必ず失敗するスタブに差し替え、probe リポジトリの
# current branch で block/allow が決まるようにする。ネットワークにも
# 実行者の認証状態にも依存させない（CI で緑・手元で赤、を作らないため）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/protect-branches.sh"
PASS=0; FAIL=0

# 合成発火を防御台帳へ source=real で積まない（この指標は「実際に何回効いたか」）。
export AIDD_LEDGER_SOURCE=test

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# `gh` スタブ。常に失敗させることで Check 4 は「PR の head を決められない」
# 経路に入り、current branch で判定する。実 PR を引くと結果が PR の状態に
# 依存してしまい、テストが環境依存になる。
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
# bash の unset は未設定の変数に対しても 0 を返すので握り潰しは要らない。
unset GH_TOKEN GITHUB_TOKEN GH_REPO

# 保護ブランチ上の probe リポジトリ / 非保護ブランチ上の probe リポジトリ
for pair in "protected:main" "feature:feat/x"; do
  name="${pair%%:*}"; br="${pair##*:}"
  git init -q "$WORK/$name"
  git -C "$WORK/$name" symbolic-ref HEAD "refs/heads/$br"
done
[ "$(git -C "$WORK/protected" branch --show-current)" = "main" ] \
  || { echo "FATAL: probe リポジトリの current branch が main でない"; exit 1; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # 改行・タブを落とすと heredoc 検体で不正な JSON になり、hook は block では
  # なくエラー終了する。rc だけ見ていると「止まった」と誤読する。
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
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
# 既定は保護ブランチ上の probe リポジトリ
test_case() { run_case "$HOOK" protected "$@"; }

# フラグ語はここで組み立てる。素の形をこのファイルに直接書くと、**このファイルを
# 扱うコマンド自身が（未更新の）ガードに掛かって編集できなくなる。**
# #346 のテストが `+` を変数にしたのと同じ理由。
DB="--delete""-branch"

echo "=== F1 陽性対照: 削除しうる形は block のまま ==="
test_case "bare flag"                  block "gh pr merge 42 --merge $DB"
test_case "=true"                      block "gh pr merge 42 --merge $DB=true"
test_case "=1"                         block "gh pr merge 42 --merge $DB=1"
test_case "=t"                         block "gh pr merge 42 --merge $DB=t"
test_case "=True"                      block "gh pr merge 42 --merge $DB=True"
test_case "= (空値: gh がエラーにする)"  block "gh pr merge 42 --merge $DB="
# pflag のブール型は空白区切りを値として取らない。gh 2.98.0 で実測:
#   `$DB false` -> accepts at most 1 arg(s), received 2  → フラグは true
test_case "空白区切りの false は値でない" block "gh pr merge 42 --merge $DB false"

echo "--- 短縮形（修正前は 1 つも見ていなかった。ここが見逃しの本体）---"
test_case "-d"                         block "gh pr merge 42 --merge -d"
test_case "-dm (連結)"                 block "gh pr merge 42 -dm"
test_case "-md (連結・順序違い)"        block "gh pr merge 42 -md"
# `=` の値は直前の 1 文字に束縛される（pflag 実測）。-dm=false の false は m に効く。
test_case "-dm=false は -d が true"     block "gh pr merge 42 -dm=false"

echo "--- 位置を変えても網から漏れない（見逃しを増やしていないことの対照）---"
test_case "&& で連結"                   block "git status && gh pr merge 42 --merge -d"
test_case "サブシェル"                  block "( gh pr merge 42 --merge -d )"
test_case "行継続をまたぐ"              block "gh pr merge 42 --merge \\
  $DB"
# 修正前も block していた形。データ文脈の除外を入れたことで素通しに
# なっていないことを固定する（この 2 件が red なら見逃しの純増である）。
# この 2 形は測り分ける必要がある。長形は **修正前も block していた**（旧正規表現に
# 一致するため）。データ文脈の除外を素朴に入れると echo セグメントとして落ち、
# block していた入力が素通しになる = 見逃しの純増。netonly はそれを防ぐためにある。
# 短縮形は修正前 allow（見逃し）で、本 PR で塞がる側。
test_case "echo | bash (長形・修正前も block)" block "echo \"gh pr merge 42 --merge $DB\" | bash"
test_case "echo | bash (短縮形・修正前は見逃し)" block "echo \"gh pr merge 42 --merge -d\" | bash"
test_case "コマンド置換の中"            block "git commit -m \"\$(gh pr merge 42 --merge -d)\""
test_case "python3 -c 経由"            block "python3 -c \"import os; os.system('gh pr merge 42 --merge -d')\""
test_case "python3 - heredoc (本文はコード)" block "python3 - <<'PY'
import os
os.system('gh pr merge 42 --merge -d')
PY"

echo ""
echo "=== F2 陰性対照: issue #358 の実際の事故入力 ==="
# (1) 1 回目 — `=false` は「削除しない」指定
test_case "=false"                     allow "gh pr merge 355 --merge $DB=false"
test_case "=FALSE"                     allow "gh pr merge 355 --merge $DB=FALSE"
test_case "=False"                     allow "gh pr merge 355 --merge $DB=False"
test_case "=0"                         allow "gh pr merge 355 --merge $DB=0"
test_case "=f"                         allow "gh pr merge 355 --merge $DB=f"
test_case "-d=false (短縮形の否定)"     allow "gh pr merge 355 --merge -d=false"
# (2) 2 回目 — issue 本文を heredoc で書くこと自体が止められた。
#     本文は **実行形**（bare flag）を含む。値判定だけでは通らない検体であり、
#     位置判定が効いていることの証明になる。
test_case "heredoc 本文に実行形の言及"  allow "cat > /tmp/iss.md <<'EOF'
\$ gh pr merge 355 --merge $DB
[Hook] BLOCKED: --delete-branch could delete a protected branch.
EOF"
test_case "heredoc, tee で受ける"       allow "tee /tmp/iss.md <<'EOF'
gh pr merge 355 --merge $DB
EOF"
# (3) 言及: grep / commit message
test_case "grep パターン"               allow "grep -rn -- '$DB' docs/"
# パイプを付けると hook 先頭の read-only 早期 skip は効かない。
# 新しい述語そのものが言及を通すことを見る。
test_case "grep | head (早期 skip なし)" allow "grep -rn -- '$DB' docs/ | head -20"
test_case "commit message"              allow "git commit -m 'docs: $DB の注意'"
test_case "commit message に全形"       allow "git commit -m 'docs: gh pr merge N --merge $DB の注意'"
test_case "commit message に短縮形"     allow "git commit -m 'fix: gh pr merge -d を止める'"

echo ""
echo "=== 非回帰: 保護ブランチが危険でなければ block しない ==="
# Check 4 は「保護ブランチが削除されうるとき」だけ止める規則である。
# feature ブランチ上では実行形でも allow でなければならない。全面 block へ
# 倒す実装になっていないことの対照。
run_case "$HOOK" feature "feature ブランチ上の bare flag" allow "gh pr merge 42 --merge $DB"
run_case "$HOOK" feature "feature ブランチ上の -d"        allow "gh pr merge 42 --merge -d"

echo ""
echo "=== 非回帰: 他フラグ・他サブコマンドに触っていない ==="
test_case "削除フラグなしの merge"      allow "gh pr merge 42 --merge"
test_case "--squash のみ"               allow "gh pr merge 42 --squash"
test_case "-b の値に d が入る"          allow "gh pr merge 42 --merge -bdeleted"
test_case "gh pr create"                allow "gh pr create --title x --body y"
test_case "gh pr view"                  allow "gh pr view 42 --json headRefName"
test_case "gh run list"                 allow "gh run list --limit 5"

echo ""
echo "=== F3 片側変異: 1 つずつ壊すと対応するケースだけ元の誤りへ戻る ==="
mutate() {
  # mutate <出力パス> <python 式の名前>
  local out="$1" kind="$2"
  python3 - "$HOOK" "$out" "$kind" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
kind = sys.argv[3]

if kind == "legacy":
    # 修正前の述語（全文字列に 1 本の正規表現）へ戻す
    start = src.index("has_active_delete_branch() {")
    end = src.index("\n}\n", start) + len("\n}\n")
    legacy = (
        "has_active_delete_branch() {\n"
        "  echo \"$1\" | grep -qE 'gh\\s+pr\\s+merge.*--delete-branch'\n"
        "}\n"
    )
    src = src[:start] + legacy + src[end:]
elif kind == "value":
    # 値の判定を消す: どの値も「偽」と認めない
    old = """    function is_false_val(v) {
      return (v == "0" || v == "f" || v == "F" ||
              v == "FALSE" || v == "false" || v == "False")
    }"""
    assert old in src, "is_false_val の形が変わっている"
    src = src.replace(old, "    function is_false_val(v) { return 0 }")
elif kind == "heredoc":
    # heredoc の位置判定を消す: 本文を落とさず素通しにする
    start = src.index("strip_dataonly_heredoc_bodies() {")
    end = src.index("\n}\n", start) + len("\n}\n")
    src = src[:start] + "strip_dataonly_heredoc_bodies() {\n  printf '%s' \"$1\"\n}\n" + src[end:]
elif kind == "segment":
    # セグメントの位置判定を消す: データ文脈の除外を無効化する
    assert "  local netonly=0\n" in src, "netonly の形が変わっている"
    src = src.replace("  local netonly=0\n", "  local netonly=1\n")
else:
    raise SystemExit("unknown mutation " + kind)

open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
  bash -n "$out" 2>/dev/null
}

for kind in legacy value heredoc segment; do
  MUT="$WORK/mut-$kind.sh"
  if mutate "$MUT" "$kind"; then
    echo "  PASS: 変異版[$kind] が構文として成立している"; PASS=$((PASS + 1))
  else
    echo "  FAIL: 変異版[$kind] の生成に失敗（この節の結果は無意味）"; FAIL=$((FAIL + 1))
    continue
  fi
  case "$kind" in
    legacy)
      # 修正前の述語では 4 つの誤検知が再現し、`-d` の見逃しも再現する。
      # これが「修正前は red だった」の再現可能な証拠である。
      run_case "$MUT" protected "  [legacy] =false が block へ戻る"    block "gh pr merge 355 --merge $DB=false"
      run_case "$MUT" protected "  [legacy] heredoc 本文が block へ戻る" block "cat > /tmp/iss.md <<'EOF'
\$ gh pr merge 355 --merge $DB
EOF"
      run_case "$MUT" protected "  [legacy] commit 全形が block へ戻る" block "git commit -m 'docs: gh pr merge N --merge $DB の注意'"
      run_case "$MUT" protected "  [legacy] -d が allow へ戻る(見逃し)"  allow "gh pr merge 42 --merge -d"
      run_case "$MUT" protected "  [legacy] bare flag は変わらず block"  block "gh pr merge 42 --merge $DB"
      ;;
    value)
      run_case "$MUT" protected "  [value] =false が block へ戻る"      block "gh pr merge 355 --merge $DB=false"
      run_case "$MUT" protected "  [value] -d=false が block へ戻る"    block "gh pr merge 355 --merge -d=false"
      run_case "$MUT" protected "  [value] heredoc 本文は allow のまま"  allow "cat > /tmp/iss.md <<'EOF'
\$ gh pr merge 355 --merge $DB
EOF"
      run_case "$MUT" protected "  [value] bare flag は変わらず block"   block "gh pr merge 42 --merge $DB"
      ;;
    heredoc)
      run_case "$MUT" protected "  [heredoc] 本文の言及が block へ戻る"  block "cat > /tmp/iss.md <<'EOF'
\$ gh pr merge 355 --merge $DB
EOF"
      run_case "$MUT" protected "  [heredoc] =false は allow のまま"     allow "gh pr merge 355 --merge $DB=false"
      run_case "$MUT" protected "  [heredoc] bare flag は変わらず block" block "gh pr merge 42 --merge $DB"
      ;;
    segment)
      run_case "$MUT" protected "  [segment] commit 全形が block へ戻る" block "git commit -m 'docs: gh pr merge N --merge $DB の注意'"
      run_case "$MUT" protected "  [segment] =false は allow のまま"     allow "gh pr merge 355 --merge $DB=false"
      run_case "$MUT" protected "  [segment] bare flag は変わらず block" block "gh pr merge 42 --merge $DB"
      ;;
  esac
done

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
