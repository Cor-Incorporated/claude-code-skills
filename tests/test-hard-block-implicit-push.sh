#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/protect-branches.sh
# NEGATIVE-TEST-FOR: hooks/git-push-guard.sh
#
# 暗黙ブランチへの push をハードブロック 2 本が止めることを固定する（F22 / F22b、2026-10-30）。
#
# 発端（統括の独立ドライラン 2026-10-30 12:00、develop の checkout 上）:
#   git push                 protect-branches rc=1  git-push-guard rc=0
#   git push origin HEAD     protect-branches rc=0  git-push-guard rc=0
#   rc=1 は「非ブロックのエラー」なので、Claude Code はそのまま push を通す。
#   サーバ側の branch protection（strict required check、enforce_admins）が最後の砦だった。
#
# 原因:
#   protect-branches.sh Check 3b は `set -euo pipefail` の下で
#     push_target=$(echo "$cmd_norm" | grep -oE "push[[:space:]]+[^|;&)<>]*" | ...)
#   を実行する。素の `git push` には `push` の後に空白が無く grep が 1 を返し、
#   pipefail + set -e で代入ごと終了する（bash -x の最終行が `push_target=`）。
#   git-push-guard.sh §2 は明示の ref しか見ず、§1 の暗黙ブランチ判定は force 限定だった。
#   どちらも `HEAD` を current に解決しない。git-push-guard.sh §2 は `xargs` が
#   奇数個の引用符で `unterminated quote` を出して rc=1 になる（2026-10-30 transcript で実測）。
#
# 軸:
#   B  陽性: 保護ブランチを更新する push は 2 本とも rc=2（暗黙・HEAD・-C・cd・.cwd・@{push}）
#   A  陰性: feature ブランチ・非保護の明示 ref・tags だけの push は 2 本とも rc=0
#   E  rc=1 はどの行にも出ない（非ブロックのエラー = 素通り）
#   L  rc=2 の行は ADR-006 台帳に hook 名つきの deny 行を 1 行以上積む
#   P  2 本が同じ解決器を持つ（_push_dests_py の本文が一字一句同じ）
#   M  片側変異: 解決器の出力を捨てると暗黙 push が再び rc=0 になる
#
# hook の process cwd は Bash ツールの cwd とは限らない。行ごとに process cwd と
# 入力 JSON の .cwd を分けて与え、.cwd と `-C` / `cd` の側で判定していることを固定する。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB="${PB_HOOK:-$SCRIPT_DIR/../hooks/protect-branches.sh}"
PG="${PG_HOOK:-$SCRIPT_DIR/../hooks/git-push-guard.sh}"
PASS=0; FAIL=0
export AIDD_LEDGER_SOURCE=test

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
# aidd_ledger_append は $HOME/.claude/hooks/ledger/ へ書く。hook だけを一時 HOME で
# 走らせ、本物の台帳にテスト行を積まずに「積んだこと」を数える。
HOOK_HOME="$FIX/home"
LEDGER="$HOOK_HOME/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$(dirname "$LEDGER")"
: > "$LEDGER"

mkrepo() {  # mkrepo <dir> <branch>
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD "refs/heads/$2"
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$1" remote add origin "$FIX/remote.git"
}
git init -q --bare "$FIX/remote.git"
DEV="$FIX/dev"; FEAT="$FIX/feat"; UP="$FIX/up"; SPACE="$FIX/dev with space"; PLAIN="$FIX/plain"
mkrepo "$DEV" develop
mkrepo "$FEAT" feat/xxx
mkrepo "$SPACE" develop
mkdir -p "$PLAIN"
# feature ブランチだが push.default=upstream で上流が develop: 素の push は develop を更新する
mkrepo "$UP" feat/up
git -C "$UP" update-ref refs/remotes/origin/develop HEAD
git -C "$UP" config push.default upstream
git -C "$UP" config branch.feat/up.remote origin
git -C "$UP" config branch.feat/up.merge refs/heads/develop

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# run_hook <hook> <process-cwd> <json-cwd> <cmd> → rc
run_hook() {
  local rc=0
  printf '{"session_id":"t","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' \
    "$(json_escape "$4")" "$(json_escape "$3")" \
    | (cd "$2" && HOME="$HOOK_HOME" bash "$1" >/dev/null 2>"$FIX/stderr") || rc=$?
  printf '%s' "$rc"
}

# row <expect-rc> <process-cwd> <json-cwd> <label> <cmd>
row() {
  local expect="$1" proc="$2" jcwd="$3" label="$4" cmd="$5" hook name rc before after
  for hook in "$PB" "$PG"; do
    name=$(basename "$hook" .sh)
    before=$(grep -c "\"hook\":\"$name\".*\"decision\":\"deny\"" "$LEDGER" || true)
    rc=$(run_hook "$hook" "$proc" "$jcwd" "$cmd")
    after=$(grep -c "\"hook\":\"$name\".*\"decision\":\"deny\"" "$LEDGER" || true)
    if [ "$rc" = "1" ]; then
      echo "  FAIL: [E] [$name] $label rc=1 (非ブロックのエラー = 素通り) stderr=$(head -c 160 "$FIX/stderr")"
      FAIL=$((FAIL + 1))
    elif [ "$rc" != "$expect" ]; then
      echo "  FAIL: [$name] $label expected rc=$expect actual rc=$rc cmd=$cmd"
      FAIL=$((FAIL + 1))
    elif [ "$expect" = "2" ] && [ "$after" -le "$before" ]; then
      echo "  FAIL: [L] [$name] $label rc=2 だが台帳に deny 行が増えていない (before=$before after=$after)"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS: [$name] $label rc=$rc"
      PASS=$((PASS + 1))
    fi
  done
}

echo "=== B 陽性: 保護ブランチを更新する push は rc=2 ==="
row 2 "$PLAIN" "$DEV"  "B1 develop 上の素の git push（.cwd=develop）"     'git push'
row 2 "$FEAT"  "$DEV"  "B1b process cwd が feature でも .cwd=develop なら止める" 'git push'
row 2 "$PLAIN" "$FEAT" "B2 -C <develop> の素の push（.cwd=feature）"      "git -C $DEV push"
row 2 "$PLAIN" "$DEV"  "B3 origin HEAD（develop 上）"                       'git push origin HEAD'
row 2 "$PLAIN" "$FEAT" "B4 HEAD:develop（feature 上でも宛先が develop）"    'git push origin HEAD:develop'
row 2 "$PLAIN" "$FEAT" "B5 :develop（保護ブランチの削除）"                  'git push origin :develop'
row 2 "$PLAIN" "$FEAT" "B6 origin develop"                                  'git push origin develop'
row 2 "$PLAIN" "$FEAT" "B7 -u origin develop"                               'git push -u origin develop'
row 2 "$PLAIN" "$FEAT" "B8 -C <develop> push origin develop"                "git -C $DEV push origin develop"
row 2 "$PLAIN" "$DEV"  "B9 remote だけ指定（develop 上）"                   'git push origin'
row 2 "$PLAIN" "$FEAT" "B10 cd <develop> && git push（.cwd=feature）"       "cd $DEV && git push"
row 2 "$PLAIN" "$FEAT" "B11 末尾コメントに奇数個の引用符"                   "git push origin develop # it's done"
row 2 "$PLAIN" "$FEAT" "B12 保護 ref が最後の refspec でない"               'git push origin develop feat/xxx'
row 2 "$PLAIN" "$UP"   "B13 push.default=upstream で上流が develop"         'git push'
row 2 "$PLAIN" "$DEV"  "B14 develop 上の暗黙 force（.cwd=develop）"         'git push --force'
row 2 "$PLAIN" "$FEAT" "B15 -C の値に空白（引用つき）"                      "git -C \"$SPACE\" push"
row 2 "$PLAIN" "$DEV"  "B16 @ は HEAD の別名"                               'git push origin @'
row 2 "$PLAIN" "$FEAT" "B17 -C <develop> の暗黙 force（.cwd=feature）"     "git -C $DEV push --force"

echo ""
echo "=== A 陰性: 保護ブランチを更新しない push は rc=0 ==="
row 0 "$PLAIN" "$FEAT" "A1 feature 上の素の git push"                       'git push'
row 0 "$DEV"   "$FEAT" "A1b process cwd が develop でも .cwd=feature なら通す" 'git push'
row 0 "$PLAIN" "$DEV"  "A2 origin release/v0.9.2（develop 上）"             'git push origin release/v0.9.2'
row 0 "$PLAIN" "$DEV"  "A3 origin feat/xxx（develop 上）"                   'git push origin feat/xxx'
row 0 "$PLAIN" "$DEV"  "A4 -u origin feat/xxx（develop 上）"                'git push -u origin feat/xxx'
row 0 "$PLAIN" "$DEV"  "A5 -C <feature> の素の push（.cwd=develop）"        "git -C $FEAT push"
row 0 "$PLAIN" "$DEV"  "A6 cd <feature> && git push（.cwd=develop）"        "cd $FEAT && git push"
row 0 "$PLAIN" "$FEAT" "A7 origin HEAD（feature 上）"                       'git push origin HEAD'
row 0 "$PLAIN" "$DEV"  "A8 HEAD:feat/xxx（develop 上でも宛先は feature）"   'git push origin HEAD:feat/xxx'
row 0 "$PLAIN" "$DEV"  "A9 develop:feat/xxx（宛先は feature）"              'git push origin develop:feat/xxx'
row 0 "$PLAIN" "$DEV"  "A10 tag だけの明示 push（develop 上）"              'git push origin v1.0.0'
row 0 "$PLAIN" "$DEV"  "A11 feature の削除（develop 上）"                   'git push origin --delete feat/old'
row 0 "$PLAIN" "$FEAT" "A12 feature 上の素の push + 末尾コメント"           "git push # it's done"
row 0 "$DEV"   "$DEV"  "A13 -C <feature> の暗黙 force（.cwd=develop）"     "git -C $FEAT push --force"
row 0 "$DEV"   "$FEAT" "A14 feature 上の暗黙 force（process cwd=develop）" 'git push --force'

echo ""
echo "=== P 対: 2 本の解決器が一字一句同じ ==="
extract_py() {
  awk '/^IFS= read -r -d .. _push_dests_py <<.PY. \|\| true$/{f=1; next} f && /^PY$/{exit} f' "$1"
}
PB_PY=$(extract_py "$PB"); PG_PY=$(extract_py "$PG")
PB_SUM=$(printf '%s' "$PB_PY" | shasum -a 256 | cut -c1-12)
PG_SUM=$(printf '%s' "$PG_PY" | shasum -a 256 | cut -c1-12)
if [ -n "$PB_PY" ] && [ "$PB_PY" = "$PG_PY" ]; then
  echo "  PASS: [P] _push_dests_py 同一 (protect-branches=$PB_SUM git-push-guard=$PG_SUM)"; PASS=$((PASS + 1))
else
  echo "  FAIL: [P] _push_dests_py が不一致 (protect-branches=$PB_SUM lines=$(printf '%s' "$PB_PY" | wc -l | tr -d ' ') git-push-guard=$PG_SUM lines=$(printf '%s' "$PG_PY" | wc -l | tr -d ' '))"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M 片側変異: 解決器の出力を捨てると暗黙 push が通る ==="
# 解決器を実行する 1 行を空出力に差し替える。陽性 B1 が rc=0 に戻り、明示の B6 は
# 従来の明示 ref 検査が残るので rc=2 のまま（変異が解決器だけに効いている確認）。
for hook in "$PB" "$PG"; do
  name=$(basename "$hook" .sh)
  MUT="$FIX/$name.mut.sh"
  python3 - "$hook" "$MUT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'python3 -c "$_push_dests_py"'
assert src.count(old) == 1, "mutation target missing: resolver call (count=%d)" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "true"))
PY
  rc=$(run_hook "$MUT" "$PLAIN" "$DEV" 'git push')
  if [ "$rc" = "0" ]; then
    echo "  PASS: [M] [$name] 変異版で B1 が rc=0 に戻る（このテストは解決器の欠落を検出する）"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [M] [$name] 変異版でも B1 が rc=$rc（テストが解決器を見ていない）"; FAIL=$((FAIL + 1))
  fi
  rc=$(run_hook "$MUT" "$PLAIN" "$FEAT" 'git push origin develop')
  if [ "$rc" = "2" ]; then
    echo "  PASS: [M] [$name] 変異版でも明示 B6 は rc=2"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [M] [$name] 変異版で明示 B6 が rc=$rc"; FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
