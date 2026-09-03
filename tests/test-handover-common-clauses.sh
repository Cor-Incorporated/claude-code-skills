#!/usr/bin/env bash
# ブリーフ共通条項 — skills/handover/common-clauses.md の結線テスト.
#
# Issue: Cor-Incorporated/aidd-governance#91 項目 3
#
# 起点:
#   監督は 4 レーンへ同時に委任し、うち 1 本のブリーフにだけ
#   「store は再実装しない」を書き、他へ写し忘れた。落とした側が develop 既存の
#   4 ファイルを独立に再実装し、add/add 競合 4 件・650 行 対 290 行で全損した。
#   2026-09-03 にも同じ構図が出た（共有チェックアウトの注意書きを毎回手写し）。
#
# 本スイートが守るもの:
#   共通条項が **1 ファイルにあり、skill から参照され、内容が実際に条項である**こと。
#   「ファイルを作った」だけでは #91 は閉じない。skill が参照していなければ
#   誰も連結せず、手写しに戻る。**宣言（SKILL.md）と実体（common-clauses.md）を
#   機械的に結ぶ**のがここの役目である。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/handover/SKILL.md"
CLAUSES="$ROOT/skills/handover/common-clauses.md"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

echo "=== 存在と結線（片方だけでは #91 は閉じない） ==="
[ -f "$CLAUSES" ] \
  && ok "共通条項が 1 ファイルとして存在する" \
  || bad "common-clauses.md が無い"
[ -f "$SKILL" ] \
  && ok "handover SKILL.md が存在する" \
  || bad "SKILL.md が無い"

# 宣言↔実体のリンク: SKILL.md が実体ファイルを名指しで参照していること。
# コメントで「keep in sync」と書くのは対策ではない。片方を消したら落ちること。
grep -q 'common-clauses\.md' "$SKILL" \
  && ok "SKILL.md が common-clauses.md を名指しで参照する（連結の指示が実在する）" \
  || bad "SKILL.md が共通条項ファイルを参照していない = 誰も連結しない"

grep -q '要約・抜粋' "$SKILL" \
  && ok "SKILL.md が「要約・抜粋しない」を指示する（言い換えで不揃いが戻るのを防ぐ）" \
  || bad "SKILL.md に要約禁止の指示がない"

grep -q '共通条項' "$SKILL" \
  && ok "文書テンプレートに共通条項の挿入点がある" \
  || bad "テンプレートに挿入点がない = 生成物へ入らない"

echo
echo "=== プレースホルダが残っていないこと（#91 の実測: 「触ってよい: ...」のまま） ==="
# 2026-09-03 実測: SKILL.md:140 は `- 触ってよい: ...` のプレースホルダのままで、
# issue が名指しした注意文は skills/ 配下 grep で 0 件だった。
if grep -qE '^- 触ってよい: \.\.\.$' "$SKILL"; then
  bad "所有範囲がプレースホルダ「...」のまま = 何も指示していない"
else
  ok "所有範囲のプレースホルダが実指示に置き換わっている"
fi

echo
echo "=== 条項の中身（#91 と 2026-09-03 の事故が名指しで入っていること） ==="
# 「ファイルはあるが中身が空」を防ぐ。各項目は実際の事故に対応する。
while IFS='|' read -r needle label; do
  [ -z "$needle" ] && continue
  if grep -q "$needle" "$CLAUSES"; then
    ok "条項: $label"
  else
    bad "条項が欠けている: $label（grep '$needle'）"
  fi
done <<'EOF'
worktree add|worktree を切る手順が実コマンドで書いてある
共有チェックアウトのブランチを切り替えない|事故 2（ブランチ切替）
git add -A|事故 1 後半（無差別ステージング）
握り潰|事故 1 根因（失敗の握り潰し）
origin/<base>|基点を明示する指示（#91 項目 1）
再実装しない|重複実装の回避（#91 の元事故）
LANE_PATHS|担当領域の宣言（#91 項目 2）
Evidence:|証跡トレーラー
EOF

echo
echo "=== 実値主義: 参照だけの記述を条項に残さない ==="
# runbook.md の実値主義。「関連ファイル」「適切な〜」のような参照は欠陥。
if grep -qE '適切な[^。]*を(入力|指定)|関連ファイル(を)?(参照|更新)せよ' "$CLAUSES"; then
  bad "参照だけの記述が条項に残っている（実値主義違反）"
else
  ok "参照だけの記述が無い"
fi

echo
echo "=== 陰性テスト: 検査器そのものを反証する ==="
# 「テストはあるが何も見ていない」を防ぐ。条項を 1 行削ったら red になること。
#
# 再帰ガード: 陰性テストは本スイート自身のコピーを起動する。ガードが無いと
# コピーがまた陰性テストを走らせ、無限再帰する（実測で踏んだ: 120 秒 timeout）。
# 子は本節を飛ばし、上の検査だけを実行して終わる。
if [ -n "${HANDOVER_CLAUSES_CHILD:-}" ]; then
  echo "SKIP: 陰性テストの子プロセスなので再帰しない"
  echo "--- $pass passed, $fail failed ---"
  [[ "$fail" -eq 0 ]]
  exit $?
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skills/handover" "$TMP/tests"
cp "$SKILL" "$TMP/skills/handover/SKILL.md"
grep -v '共有チェックアウトのブランチを切り替えない' "$CLAUSES" > "$TMP/skills/handover/common-clauses.md"
cp "$0" "$TMP/tests/$(basename "$0")"
if HANDOVER_CLAUSES_CHILD=1 bash "$TMP/tests/$(basename "$0")" >/dev/null 2>&1; then
  bad "陰性(条項削除) 条項を 1 行消しても緑 = 中身を見ていない"
else
  ok "陰性(条項削除) 条項を 1 行消すと red になる"
fi

# 結線を切ったら red になること（ファイルはあるが誰も参照しない状態）
mkdir -p "$TMP/b/skills/handover" "$TMP/b/tests"
grep -v 'common-clauses\.md' "$SKILL" > "$TMP/b/skills/handover/SKILL.md"
cp "$CLAUSES" "$TMP/b/skills/handover/common-clauses.md"
cp "$0" "$TMP/b/tests/$(basename "$0")"
if HANDOVER_CLAUSES_CHILD=1 bash "$TMP/b/tests/$(basename "$0")" >/dev/null 2>&1; then
  bad "陰性(結線切断) SKILL.md の参照を消しても緑 = リンクを見ていない"
else
  ok "陰性(結線切断) SKILL.md の参照を消すと red になる"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
