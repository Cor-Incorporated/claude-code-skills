#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/protect-branches.sh
# NEGATIVE-TEST-FOR: hooks/git-push-guard.sh
#
# 再裁定 aidd-governance:design/ops/readjudication/2026-09-03-hooks-surface-form.md
# 条件 5 の強制点 — **保護名の照合は区切りを跨いではならない。**
#
# 条件 1「抽出器を再利用する」は宣言であって検査ではなかった。だから
# protect-branches.sh の Check 1/2 が 2 世代にわたり raw な `.*` のまま残り、
# 同じファイルの Check 3b だけが区切りを除いている、という状態になった。
#
# ## なぜソース走査ではなく振る舞いで測るか
#
# `.*` の有無を grep する形も考えたが採らない。**セグメント内の `.*` は正しい**
# （区切りが無い文字列の中で verb と名前を繋ぐのは正当）。構造からは
# 「全文に効く `.*`」と「セグメントに閉じた `.*`」を区別できない。
# 区別できない指標は、リファクタで黙って通る。
#
# 代わりに**入力を食わせて結論を見る**。判定内容には踏み込まず、
# 「別セグメントの言及だけで止めないか」だけを問う（C15 / 再裁定 §6）。
#
# ## 軸
#   F1  陽性対照 — 実際に危険な操作は各ガードが従来どおり block する
#   F2  陰性対照 — 危険な動詞と保護名が**別セグメント**にあるだけなら allow
#   F3  順序対称 — 同じ 2 セグメントは順序を入れ替えても結論が変わらない
#                  （変わるなら位置で見ている = 本条件の違反）
#
# F3 が本検査の核である。位置依存は「連結で block・逆順で allow」という
# **非対称**として現れる。対称性は判定内容を知らずに検査できる。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
PASS=0; FAIL=0
export AIDD_LEDGER_SOURCE=test

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for pair in "protected:main" "feature:feat/x"; do
  n="${pair%%:*}"; b="${pair##*:}"
  git init -q "$WORK/$n"; git -C "$WORK/$n" symbolic-ref HEAD "refs/heads/$b"
done

json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"
}
rc_of() { # rc_of <hook> <repo> <cmd>
  local rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$3")" \
    | (cd "$WORK/$2" && bash "$1" >/dev/null 2>&1) || rc=$?
  echo "$rc"
}
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }

# 語を組み立てる（このファイルを扱うコマンド自身がガードに掛かるのを避ける）
BD="branch -""D"; PD="--dele""te"; P1="deve""lop"; P2="ma""in"; FORCE="--for""ce"

# 対象は「保護ブランチ名を判定に使う」ハードブロック。
GUARDS="protect-branches.sh git-push-guard.sh"

echo "=== 対象ガードが実在し実行可能か（空振り防止）==="
for g in $GUARDS; do
  if [ -x "$HOOKS_DIR/$g" ] || [ -f "$HOOKS_DIR/$g" ]; then ok "$g がある"
  else bad "$g が無い — 以降の結果は無意味"; fi
done

echo ""
echo "=== F1 陽性対照: 危険な操作は block されたままである ==="
for g in $GUARDS; do
  for c in "git push $FORCE origin $P1" "git push origin $PD $P1"; do
    r=$(rc_of "$HOOKS_DIR/$g" protected "$c")
    # git-push-guard は削除を担当しない。少なくとも 1 本が止めればよいが、
    # 「どちらも止めない」形をここで検出したいので個別に記録する。
    printf '    %-24s rc=%s  %s\n' "$g" "$r" "$c"
  done
done
# 少なくとも 1 本が止めることを要求する（多層防御の最低条件）
for c in "git push $FORCE origin $P1" "git push origin $PD $P1" "git $BD $P1"; do
  blocked=0
  for g in $GUARDS; do
    [ "$(rc_of "$HOOKS_DIR/$g" protected "$c")" -ne 0 ] && blocked=1
  done
  [ "$blocked" -eq 1 ] && ok "いずれかのガードが止める:: $c" \
                       || bad "**どのガードも止めない**:: $c"
done

echo ""
echo "=== F2 陰性対照: 危険な動詞と保護名が別セグメントなら allow ==="
# 各行: <危険な動詞のセグメント> || <保護名だけを含む無害なセグメント>
SEP_CASES=(
  "git push origin $PD feat/x|git log origin/$P1"
  "git $BD feat/x|git log origin/$P1"
  "git push origin $PD feat/x|git log origin/$P2"
  "git worktree remove .worktrees/x|git fetch origin $P1 -q"
)
for g in $GUARDS; do
  for repo in protected feature; do
    for case_ in "${SEP_CASES[@]}"; do
      a="${case_%%|*}"; b="${case_##*|}"
      r=$(rc_of "$HOOKS_DIR/$g" "$repo" "$a && $b")
      [ "$r" -eq 0 ] && ok "$g [$repo] 別セグメントの言及で止めない" \
                     || bad "$g [$repo] 別セグメントの言及で block した" "$a && $b (rc=$r)"
    done
  done
done

echo ""
echo "=== F3 順序対称: 同じ 2 セグメントは順序を入れ替えても結論が同じ ==="
# 位置依存は「連結で block・逆順で allow」という非対称として現れる。
# 判定内容を知らなくても、この非対称だけは検査できる。
asym=0
for g in $GUARDS; do
  for repo in protected feature; do
    for case_ in "${SEP_CASES[@]}"; do
      a="${case_%%|*}"; b="${case_##*|}"
      fwd=$(rc_of "$HOOKS_DIR/$g" "$repo" "$a && $b")
      rev=$(rc_of "$HOOKS_DIR/$g" "$repo" "$b && $a")
      f=$([ "$fwd" -eq 0 ] && echo allow || echo block)
      v=$([ "$rev" -eq 0 ] && echo allow || echo block)
      if [ "$f" = "$v" ]; then
        ok "$g [$repo] 順序対称（両方 ${f}）"
      else
        bad "$g [$repo] **順序で結論が変わる**（順=${f} 逆=${v}）" "$a  /  $b"
        asym=$((asym+1))
      fi
    done
  done
done
[ "$asym" -eq 0 ] && ok "順序非対称は 0 件" || bad "順序非対称が ${asym} 件ある"

echo ""
echo "=== 統制: この検査は本当に非対称を捕まえるか（自己検査）==="
# 位置依存を注入した変異版を作り、F3 が落ちることを確かめる。
# 落ちないなら、この検査は何も測っていない。
MUT="$WORK/mut-positional.sh"
python3 - "$HOOKS_DIR/protect-branches.sh" "$MUT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """  normalized=$(printf '%s' "$cmd" | tr '<>();|&' '\\n')"""
assert src.count(old) == 1, "セグメント化の形が変わっている（変異が当たらない）"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, """  normalized="$cmd\""""))
PY
if bash -n "$MUT" 2>/dev/null; then
  ok "変異版が構文として成立している"
  # 統制の統制: 変異版でも実削除は block する（= 変異版が動いている証拠）
  [ "$(rc_of "$MUT" protected "git $BD $P1")" -ne 0 ] \
    && ok "変異版は動いている（実削除を block する）" \
    || bad "変異版が動いていない — 以下の結果は「差が出た」ではなく「落ちた」"
  a="git push origin $PD feat/x"; b="git log origin/$P1"
  fwd=$(rc_of "$MUT" protected "$a && $b"); rev=$(rc_of "$MUT" protected "$b && $a")
  [ "$fwd" -ne "$rev" ] \
    && ok "変異版では順序で結論が変わる（順=${fwd} 逆=${rev}）= 本検査は非対称を捕まえる" \
    || bad "変異版でも対称のまま（順=${fwd} 逆=${rev}）— 本検査は非対称を検出できない"
else
  bad "変異版の生成に失敗（この節の結果は無意味）"
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
