#!/bin/bash
# NEGATIVE-TEST-FOR: scripts/h5-vendor-lint.sh
# vendor 成果物に対する検査集合の宣言と実行 (aidd-governance#152)
#
# 起点: 単一正本 + vendoring (#137) を入れてから、正本の欠陥が 3 回とも
# **消費側の CI でしか**検出されなかった。正本側は 3 回とも緑だった。
# 向きを反転しても再発したので、構造の問題である。
#
# 実測 (2026-09-03、本装置の導入前):
#   scripts/h5-admission-check.sh に SC2034 が 2 件あり、**どちらの CI も
#   見ていなかった。** ccs は shellcheck を hooks/*.sh にしかかけず、
#   gov は h5-source-check.sh だけを明示列挙していた。欠陥は実在した。
#
# 軸:
#   F1  陽性 — 宣言どおりに走り、走らせた検査集合を出力する（完了条件 3）
#   F2  fail-closed — 宣言が無い / 空 / 対象欠落 / コマンド不在で **red**。
#                     「検査していないのに緑」を作らない
#   F3  片側変異 — 検査を 1 つ外すと、その検査でしか落ちない検体が素通りする
#   C2  迂回検出 — ワークフローが宣言を通さず直接 linter を呼んでいないか
#                  （完了条件 2 の片側）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/h5-vendor-lint.sh"
DECL="$ROOT/.aidd-h5-vendor-lint"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 実行器は $0 相対で ROOT を決めるので、検体リポジトリを作って
# その中に置く。**リポジトリ外に置くと ROOT が壊れ、「変異が効いた」ではなく
# 「動かなかった」で赤くなる**（2026-09-03 に 2 回踏んだ形）。
mk_repo() { # mk_repo <dir>
  mkdir -p "$1/scripts"
  cp "$RUNNER" "$1/scripts/h5-vendor-lint.sh"
}
run_in() { # run_in <repo> -> rc（出力は $LAST_OUT）
  LAST_OUT="$(bash "$1/scripts/h5-vendor-lint.sh" 2>&1)"
  return $?
}

echo "=== F1 陽性: このリポジトリで宣言どおり走る ==="
LAST_OUT="$(bash "$RUNNER" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "本番リポジトリで green" || bad "本番で red" "$LAST_OUT"

echo ""
echo "--- 完了条件 3: 走らせた検査集合が出力から読める ---"
for needle in "artifact scripts/h5-admission-check.sh" "artifact scripts/h5-source-check.sh" "check syntax" "check lint"; do
  case "$LAST_OUT" in
    *"$needle"*) ok "出力に含まれる -- ${needle}" ;;
    *) bad "出力に無い -- ${needle}" ;;
  esac
done
# grep -c は 0 件のとき rc=1 を返す。件数は stdout に出るので値は使えるが、
# ファイルが読めない場合 (rc=2) と区別する。
n_decl="$(grep -c '^artifact ' "$DECL")"; grc=$?
if [ "$grc" -ge 2 ]; then
  bad "宣言ファイルを読めない (grep rc=${grc}) -- ${DECL}"
  n_decl=-1
fi
case "$LAST_OUT" in
  *"artifacts=${n_decl}"*) ok "artifact 件数が宣言と一致 -- ${n_decl}" ;;
  *) bad "artifact 件数が出力と宣言でずれる" "宣言=${n_decl}" ;;
esac

echo ""
echo "=== F2 fail-closed: 検査していないのに緑を作らない ==="

R="$WORK/no-decl"; mk_repo "$R"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "宣言ファイルが無ければ red (rc=${rc})" || bad "宣言が無いのに green"

R="$WORK/empty"; mk_repo "$R"; printf '# comment only\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "artifact 0 件なら red (rc=${rc})" || bad "空宣言で green"

R="$WORK/no-check"; mk_repo "$R"
printf 'artifact scripts/h5-vendor-lint.sh\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "check 0 件なら red (rc=${rc})" || bad "check 無しで green"

R="$WORK/missing-artifact"; mk_repo "$R"
printf 'artifact scripts/does-not-exist.sh\ncheck syntax bash -n {}\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "宣言された artifact が無ければ red (rc=${rc})" || bad "対象欠落で green"

R="$WORK/no-cmd"; mk_repo "$R"
printf 'artifact scripts/h5-vendor-lint.sh\ncheck bogus definitely-not-a-real-command-xyz {}\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "検査コマンドが無ければ red (rc=${rc})"
  case "$LAST_OUT" in
    *127*) ok "exit 127 を「合格」と読まず明示する" ;;
    *) bad "127 の扱いが出力に出ない" "$LAST_OUT" ;;
  esac
else
  bad "コマンド不在で green（実行できなかったことを合格と読んでいる）"
fi

R="$WORK/no-brace"; mk_repo "$R"
printf 'artifact scripts/h5-vendor-lint.sh\ncheck bad bash -n\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "check に {} が無ければ red (rc=${rc})" || bad "{} 無しで green（対象が渡っていない）"

echo ""
echo "=== F3 片側変異: 検査を外すと、その検査でしか落ちない検体が素通りする ==="
# lint でしか落ちない検体（構文は正しいが未使用変数がある）
mk_bad() { printf '#!/usr/bin/env bash\nset -euo pipefail\nUNUSED_ON_PURPOSE="x"\necho ok\n' > "$1"; }

R="$WORK/mut-both"; mk_repo "$R"; mk_bad "$R/scripts/subject.sh"
printf 'artifact scripts/subject.sh\ncheck syntax bash -n {}\ncheck lint shellcheck -x -S warning {}\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc_both=$?
[ "$rc_both" -ne 0 ] && ok "統制: lint ありなら検体は red (rc=${rc_both})" \
                     || bad "統制が成立しない — 検体が lint を通ってしまう" "$LAST_OUT"

R="$WORK/mut-nolint"; mk_repo "$R"; mk_bad "$R/scripts/subject.sh"
printf 'artifact scripts/subject.sh\ncheck syntax bash -n {}\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc_nolint=$?
[ "$rc_nolint" -eq 0 ] && ok "変異: lint 行を外すと同じ検体が green（この検査は結論を作っていた）" \
                       || bad "lint を外しても red — 落としていたのは別の検査" "$LAST_OUT"

# 統制の統制: 変異版でも構文エラーは捕まえる（= 実行器が動いている）
R="$WORK/mut-syntax"; mk_repo "$R"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n' > "$R/scripts/subject.sh"
printf 'artifact scripts/subject.sh\ncheck syntax bash -n {}\n' > "$R/.aidd-h5-vendor-lint"
run_in "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "変異版でも構文エラーは捕まえる（実行器は動いている）" \
               || bad "変異版が何も検出しない — 差ではなく故障"

echo ""
echo "=== F3b 実行器自身の片側変異: fail-closed の判定を外すと空宣言が素通りする ==="
# 宣言側の変異（F3）に加えて**実行器本体**を変異させる。
# 変異体は fixture リポジトリの中に置く — 実行器は $0 相対で ROOT を決めるので、
# リポジトリ外に置くと「変異が効いた」ではなく「宣言が見つからない」で赤くなる。
R="$WORK/mut-runner"; mkdir -p "$R/scripts"
MUT="$R/scripts/h5-vendor-lint.sh"
python3 - "$RUNNER" "$MUT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''if [[ "${#artifacts[@]}" -eq 0 ]]; then
  fail "artifact が 0 件。空の宣言で緑にはしない"
  exit 1
fi
'''
assert src.count(old) == 1, "空宣言ガードの形が変わっている（変異が当たらない）"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, ""))
PY
if bash -n "$MUT" 2>/dev/null; then
  ok "変異版（空宣言ガード除去）が構文として成立している"
  # artifact を 1 件も持たない宣言。check だけある。
  printf '# no artifact lines at all\ncheck syntax bash -n {}\n' > "$R/.aidd-h5-vendor-lint"

  # 統制: 無改変の実行器は同じ入力で red でなければならない。
  # ここが green だと「変異が効いた」ではなく「元から通る」である。
  cp "$RUNNER" "$R/scripts/control.sh"
  bash "$R/scripts/control.sh" >/dev/null 2>&1; ctl_rc=$?
  [ "$ctl_rc" -ne 0 ] && ok "統制: 無改変の実行器は空宣言で red (rc=${ctl_rc})" \
                      || bad "統制が成立しない — 無改変でも空宣言が通る"

  bash "$MUT" >/dev/null 2>&1; mut_rc=$?
  [ "$mut_rc" -eq 0 ] && ok "変異: ガードを外すと空宣言が green（このガードは結論を作っていた）" \
                      || bad "ガードを外しても red — 落としていたのは別の判定 (rc=${mut_rc})"
else
  bad "変異版の生成に失敗（この節の結果は無意味）"
fi

echo ""
echo "=== C2 迂回検出: ワークフローが宣言を通さず直接 linter を呼んでいないか ==="
# 完了条件 2 の片側。宣言の外で vendor 成果物に検査をかけると、
# 「消費側だけが持つ検査」が再び生まれる。
declared_artifacts="$(grep '^artifact ' "$DECL" | awk '{print $2}')"
bypass=0
for wf in "$ROOT"/.github/workflows/*.yml; do
  [ -f "$wf" ] || continue
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    # 実行器経由の行は除く。それ以外で artifact 名と linter が同じ行に出たら迂回。
    # grep rc: 0=一致 / 1=不一致（これが期待値）/ 2 以上=エラー。
    # 2 以上を「迂回なし」と読むと、**検査していないのに緑**になる。
    hits="$(grep -nE "(shellcheck|bash -n|shfmt)[^|]*${a//\//\\/}" "$wf" 2>/dev/null)"; grc=$?
    if [ "$grc" -ge 2 ]; then
      bad "迂回検査の grep 自体が失敗した (rc=${grc}) -- $(basename "$wf")"
      bypass=$((bypass + 1))
      continue
    fi
    hits="$(printf '%s\n' "$hits" | grep -v 'h5-vendor-lint')" || hits=""
    if [ -n "$hits" ]; then
      bad "宣言を迂回して linter を直接呼んでいる: $(basename "$wf")" "$hits"
      bypass=$((bypass + 1))
    fi
  done <<< "$declared_artifacts"
done
[ "$bypass" -eq 0 ] && ok "宣言を迂回した直接呼び出しは 0 件"

echo ""
echo "=== 実行器自身が宣言した検査を通る（自己適用）==="
for c in "bash -n" "shellcheck -x -S warning"; do
  if $c "$RUNNER" >/dev/null 2>&1; then ok "実行器自身が通る -- ${c}"
  else bad "実行器自身が落ちる -- ${c}"; fi
done

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
