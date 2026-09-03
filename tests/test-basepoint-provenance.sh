#!/usr/bin/env bash
# base の出所をブロックメッセージに出す（2026-09-03 の誤ブロック）。
#
# 起点事故: ローカルの `refs/remotes/origin/HEAD` が `main` を指したままで、
# GitHub 側の既定は `develop` だった。結果、**develop 起点の正当なレーン発射が
# 全部 block** され、メッセージは
#
#   ::error::発射しようとしている起点が origin/main より 8 commit 古い: origin/develop
#
# とだけ言った。**その `main` がどこから来たのかを言わない**ので、
# 「develop 起点なのになぜ main と比べられるのか」に辿り着けない。
#
# `origin/HEAD` は **ローカルにキャッシュされた宣言**であり、リモートの実体と
# 黙って乖離する。本セッションで繰り返し直している宣言↔実体の形である。
#
# 反証軸:
#   F2  事故の形（origin/HEAD が古い）で、出所と更新コマンドが出る
#   F2' 明示指定・推測のときはそれぞれ別の出所が出る
#   F3  出所を出す分岐を消すと、メッセージが原因に届かなくなる
#
# **実リポジトリには触らない。** すべて $TMPDIR。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lane-basepoint-check.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 台帳の書き込み先は lib が ${HOME}/.claude/hooks/ledger で決める。
# 実 HOME を汚さないよう HOME ごと差し替える。
mkdir -p "$WORK/fakehome/.claude/hooks/ledger"

# --- fixture: origin に develop と main を持ち、develop が main より進んでいる ---
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
SEED="$WORK/seed"
git init -q "$SEED"
git -C "$SEED" config user.email t@example.com
git -C "$SEED" config user.name t
git -C "$SEED" config core.hooksPath /dev/null
echo one > "$SEED/a.txt"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m base
git -C "$SEED" branch -M main
git -C "$SEED" remote add origin "file://$ORIGIN"
git -C "$SEED" push -q origin main
# **向きが重要**: 事故は「base（main）が起点（develop）より進んでいる」形だった。
# develop を先に切ってから main を 8 commit 進める。
git -C "$SEED" branch stale   # base commit のまま留め置く
git -C "$SEED" push -q origin stale
# develop は base+3
for i in 1 2 3; do
  echo "d$i" >> "$SEED/a.txt"
  git -C "$SEED" add -A
  git -C "$SEED" commit -q -m "develop $i"
done
git -C "$SEED" branch develop
git -C "$SEED" push -q origin develop
for i in 1 2 3 4 5 6 7 8; do
  echo "$i" >> "$SEED/a.txt"
  git -C "$SEED" add -A
  git -C "$SEED" commit -q -m "main $i"
done
git -C "$SEED" push -q origin main

REPO="$WORK/repo"
git clone -q -b main "file://$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" fetch -q origin main develop stale 2>/dev/null

run() { # $1=script $2..=env -> stderr を LAST_OUT へ
  local s="$1"; shift
  LAST_OUT="$(
    env "$@" AIDD_LEDGER_SOURCE=test HOME="$WORK/fakehome" \
      bash "$s" basepoint-ref "$REPO" origin/develop 2>&1 >/dev/null
  )"
  LAST_RC=$?
}

run_from() { # $1=script $2=起点
  LAST_OUT="$(
    env AIDD_LEDGER_SOURCE=test HOME="$WORK/fakehome" \
      bash "$1" basepoint-ref "$REPO" "$2" 2>&1 >/dev/null
  )"
  LAST_RC=$?
}

echo "=== 前提: fixture が意図どおりか（空振り検査） ==="
behind="$(git -C "$REPO" rev-list --count origin/develop..origin/main 2>/dev/null)"
if [[ "$behind" == "8" ]]; then
  ok "origin/develop は origin/main より 8 commit 遅れている（事故と同じ向き）"
else
  bad "fixture が壊れている（差 ${behind} commit）— 以降の結果は無意味"
fi

echo ""
echo "=== F2 起点事故: origin/HEAD が古い main を指す ==="
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run "$LIB"
if [[ "$LAST_OUT" == *"commit 古い"* ]]; then
  ok "古い起点として block する（判定そのものは従来どおり）"
else
  bad "block しない :: $LAST_OUT"
fi
if [[ "$LAST_OUT" == *"refs/remotes/origin/HEAD"* ]]; then
  ok "base の出所が origin/HEAD であることを出す"
else
  bad "出所が出ない — 原因に辿り着けない :: $LAST_OUT"
fi
if [[ "$LAST_OUT" == *"remote set-head origin -a"* ]]; then
  ok "貼れば直る更新コマンドを出す（実値主義）"
else
  bad "更新コマンドが無い :: $LAST_OUT"
fi
if [[ "$LAST_OUT" == *"キャッシュされた宣言"* ]]; then
  ok "ローカルのキャッシュであることを明示する"
else
  bad "キャッシュである旨が無い"
fi

echo ""
echo "=== F2' 明示指定のときは別の出所が出る ==="
run "$LIB" LANE_BASE=main
if [[ "$LAST_OUT" == *"LANE_BASE による明示指定"* && "$LAST_OUT" != *"set-head"* ]]; then
  ok "明示指定では set-head を勧めない（原因が違うので）"
else
  bad "明示指定でも origin/HEAD の助言が出る :: $LAST_OUT"
fi

echo ""
echo "=== F2'' origin/HEAD 未設定のときは推測と言う ==="
git -C "$REPO" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
# fallback は候補 develop を選ぶ。develop より遅れた起点でなければ block しない。
run_from "$LIB" origin/stale
if [[ "$LAST_OUT" == *"推測"* ]]; then
  ok "候補からの推測であることを出す"
else
  bad "推測である旨が無い :: $LAST_OUT"
fi
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

echo ""
echo "=== 台帳に出所が残るか ==="
if grep -q 'base_origin=origin-head' "$WORK/fakehome/.claude/hooks/ledger/guard-ledger.jsonl" 2>/dev/null; then
  ok "台帳の detail に base_origin が入る（後から集計できる）"
else
  bad "台帳に出所が無い :: $(tail -1 "$WORK/fakehome/.claude/hooks/ledger/guard-ledger.jsonl" 2>/dev/null)"
fi

echo ""
echo "=== F3 片側変異: 出所を出す分岐を消すと原因に届かなくなる ==="
MUT="$WORK/mutant.sh"
python3 - "$LIB" "$MUT" <<'PY'
import pathlib, re, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = '  case "${LANE_BASE_ORIGIN:-}" in'
assert t.count(old) == 1, f"変異対象が {t.count(old)} 件"
# case 文全体を無効化する（先頭を常に偽の分岐へ差し替える）
t2 = t.replace(old, '  case "__mutated__" in', 1)
pathlib.Path(dst).write_text(t2, encoding="utf-8")
PY
run "$MUT"
if [[ "$LAST_OUT" == *"commit 古い"* && "$LAST_OUT" != *"set-head"* ]]; then
  ok "変異体は block するが出所を出さない = 出所の分岐が結論を作っていた"
else
  bad "変異が効いていない :: $LAST_OUT"
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
