#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/enforce-hook-deploy-integrity.sh
# core.hooksPath の local override が global の hook を落としている状態の検出。
#
# 起点事故 (2026-09-02): プローブが `set -e` 無しでサンドボックスへの `cd` に失敗し、
# `git config core.hooksPath /dev/null` が実リポの aidd-governance に当たった。
# 以後その repo の commit は pre-commit（H16 秘密走査）を通らなくなったが、
# **装置は何も言わなかった。** 気づいたのは別件を調べていた偶然である。
#
# 反証軸:
#   F2  既知の事故入力（/dev/null・pre-commit を欠く実ディレクトリ）で警告が出る
#   F2' 正当な override（global と同じ hook を全部持つ）では出さない — 雑音を作らない
#   F3  片側変異（比較を落とす）で F2 が反転する
#
# **実 HOME・実リポには触らない。** すべて $TMPDIR。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/enforce-hook-deploy-integrity.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- global hooksPath を模す（5 hook） ---
GHOOKS="$WORK/global-hooks"
mkdir -p "$GHOOKS"
for h in post-checkout post-commit post-merge pre-commit pre-push; do
  printf '#!/bin/sh\nexit 0\n' > "$GHOOKS/$h"
  chmod +x "$GHOOKS/$h"
done
# .sample は global にあっても比較対象にしない
printf '#!/bin/sh\nexit 0\n' > "$GHOOKS/pre-rebase.sample"

# --- 検査対象の repo を作る ---
mk_repo() { # $1=name -> path
  local r="$WORK/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  printf 'x\n' > "$r/a.txt"
  git -C "$r" add -A
  git -C "$r" -c core.hooksPath=/dev/null commit -q -m base
  printf '%s' "$r"
}

# hook を走らせる。global config は $WORK/gitconfig に閉じ込め、実 HOME を汚さない。
# 本スクリプトは errexit を使わない（先頭は `set -uo pipefail`）。
# したがって `set +e` / `set -e` で挟まない — `set -e` で戻すと、最初の呼び出し
# 以降だけ errexit が有効になり、**後半のケースだけが途中終了する**。
# 非ゼロは代入で普通に拾える。
run_hook() { # $1=script $2=repo -> stderr を LAST_OUT へ
  LAST_OUT="$(
    HOME="$WORK/fakehome" \
    GIT_CONFIG_GLOBAL="$WORK/gitconfig" \
    CLAUDE_PROJECT_DIR="$2" \
    AIDD_LEDGER_SOURCE=test \
    H11_LEDGER_PATH="$WORK/ledger.jsonl" \
    bash "$1" 2>&1 >/dev/null
  )"
  LAST_RC=$?
}

mkdir -p "$WORK/fakehome"
# global 側に hooksPath を宣言する（GIT_CONFIG_GLOBAL 経由）
git config --file "$WORK/gitconfig" core.hooksPath "$GHOOKS"

echo "=== 前提の確認: fixture が意図どおり組めているか ==="
if [[ "$(git config --file "$WORK/gitconfig" core.hooksPath)" == "$GHOOKS" ]] \
   && [[ -x "$GHOOKS/pre-commit" ]]; then
  ok "global hooksPath が 5 hook を提供している"
else
  bad "fixture が壊れている — 以降の結果は無意味"
fi

echo ""
echo "=== F2-a 起点事故: local override = /dev/null ==="
R="$(mk_repo repo-devnull)"
git -C "$R" config --local core.hooksPath /dev/null
run_hook "$HOOK" "$R"
if [[ "$LAST_OUT" == *"core.hooksPath"* && "$LAST_OUT" == *"pre-commit"* ]]; then
  ok "/dev/null override を検出し、落ちる hook を名指しする"
else
  bad "検出しない（起点事故そのもの）" "$LAST_OUT"
fi
if [[ "$LAST_OUT" == *"--unset core.hooksPath"* ]]; then
  ok "  貼れば直る修復コマンドを出す（実値主義）"
else
  bad "  修復コマンドが無い" "$LAST_OUT"
fi

echo ""
echo "=== F2-b 実ディレクトリだが pre-commit を欠く（ccs で起きた形） ==="
R="$(mk_repo repo-samples-only)"
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit.sample"
git -C "$R" config --local core.hooksPath "$R/.git/hooks"
run_hook "$HOOK" "$R"
if [[ "$LAST_OUT" == *"pre-commit"* ]]; then
  ok ".sample しか無い override を検出する（.sample は hook として数えない）"
else
  bad "検出しない" "$LAST_OUT"
fi

echo ""
echo "=== F2-c 一部だけ落とす（pre-commit は在るが pre-push が無い） ==="
R="$(mk_repo repo-partial)"
mkdir -p "$R/myhooks"
printf '#!/bin/sh\nexit 0\n' > "$R/myhooks/pre-commit"; chmod +x "$R/myhooks/pre-commit"
git -C "$R" config --local core.hooksPath "$R/myhooks"
run_hook "$HOOK" "$R"
if [[ "$LAST_OUT" == *"pre-push"* && "$LAST_OUT" != *"失う   : pre-commit"* ]]; then
  ok "落ちたものだけを名指しする（在るものを数えない）"
else
  bad "落ちた hook の列挙が不正確" "$LAST_OUT"
fi

echo ""
echo "=== F2' 正当な override は撃たない（雑音を作らない） ==="
# opencode の .husky/_ に相当。global と同じ hook を全部持つ。
R="$(mk_repo repo-complete)"
mkdir -p "$R/.husky/_"
for h in post-checkout post-commit post-merge pre-commit pre-push; do
  printf '#!/bin/sh\nexit 0\n' > "$R/.husky/_/$h"; chmod +x "$R/.husky/_/$h"
done
git -C "$R" config --local core.hooksPath ".husky/_"
run_hook "$HOOK" "$R"
if [[ "$LAST_OUT" != *"local override"* && "$LAST_OUT" != *"失う"* ]]; then
  ok "全 hook を持つ override では撃たない（相対パスも解決できている）"
else
  bad "正当な override で撃った = 雑音" "$LAST_OUT"
fi

echo ""
echo "=== F2'' override 自体が無ければ撃たない ==="
R="$(mk_repo repo-nooverride)"
run_hook "$HOOK" "$R"
if [[ "$LAST_OUT" != *"local override"* ]]; then
  ok "override 無しでは撃たない"
else
  bad "override が無いのに撃った" "$LAST_OUT"
fi

echo ""
echo "=== 台帳 (ADR-006 要件 4) ==="
R="$(mk_repo repo-ledger)"
git -C "$R" config --local core.hooksPath /dev/null
rm -f "$WORK/ledger.jsonl"
LEDGER_HOME="$WORK/fakehome/.claude/hooks/ledger"
mkdir -p "$LEDGER_HOME"
HOME="$WORK/fakehome" GIT_CONFIG_GLOBAL="$WORK/gitconfig" CLAUDE_PROJECT_DIR="$R" \
  AIDD_LEDGER_SOURCE=test bash "$HOOK" >/dev/null 2>&1 || true
if grep -q 'hookspath-override-drops-guards' "$LEDGER_HOME/guard-ledger.jsonl" 2>/dev/null; then
  ok "発火が台帳へ届く（rule=hookspath-override-drops-guards）"
else
  bad "台帳に届かない" "$(tail -1 "$LEDGER_HOME/guard-ledger.jsonl" 2>/dev/null)"
fi

echo ""
echo "=== F3 片側変異: 比較を落とすと F2-a が反転する ==="
MUT="$WORK/mutant.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = '    [[ -x "$_lhp_abs/$_hn" ]] || _lost="${_lost}${_lost:+ }${_hn}"'
assert t.count(old) == 1, f"変異対象が {t.count(old)} 件"
pathlib.Path(dst).write_text(t.replace(old, '    :  # 変異: 落ちた hook を数えない', 1), encoding="utf-8")
PY
R="$(mk_repo repo-mutant)"
git -C "$R" config --local core.hooksPath /dev/null
run_hook "$MUT" "$R"
if [[ "$LAST_OUT" != *"local override"* ]]; then
  ok "変異体は /dev/null override を見逃す = 比較が結論を作っていた"
else
  bad "変異体でも検出した = この節は比較を証明していない" "$LAST_OUT"
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
