#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/aidd-carryover-reconcile.sh
# SessionStart 持ち越し照合 — hooks/aidd-carryover-reconcile.sh の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#96 受入基準 (3)
#
# この hook は監督の実セッション冒頭で必ず走る。したがって最優先の性質は
# 「絶対に人の作業を止めない」であり、その次が「持ち越しを見落とさない」である。
# 両方を実測する。
#
# shellcheck disable=SC2015,SC2016
#   SC2015: ok() は常に 0 を返すので `A && ok || bad` は if-then-else として働く。
#   SC2016: 変異体の置換対象は、展開させない生の文字列として単引用符で書く。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/aidd-carryover-reconcile.sh"
ASYNC="$ROOT/scripts/async-work.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
export HOME="$SB/home"
# 手で登録した持ち越しは CLAUDE_CODE_SESSION_ID のセッションに紐づく。入力の session_id "t" と
# そろえる（このテストを走らせているセッション自身の id を持ち込まない）。
export CLAUDE_CODE_SESSION_ID=t
mkdir -p "$HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

reset_state() {
  export AIDD_ASYNC_STATE="$SB/aw-$1"
  rm -rf "$AIDD_ASYNC_STATE"; mkdir -p "$AIDD_ASYNC_STATE"
}

# run_hook <hook> [env...] -> stdout は $SB/out、stderr は $SB/err、rc を返す
run_hook() {
  local hook="$1"; shift
  printf '{"session_id":"t","source":"startup"}' \
    | env "$@" bash "$hook" >"$SB/out" 2>"$SB/err"
}

# seed <id> <session> — 未解決・owner 未宣言の持ち越しを 1 件、登録したセッション付きで台帳へ置く。
# register --session を使わず保存形式へ直接書くのは、--session を解さない修正前の CLI に対しても
# 同じ前提を作るため（修正前で実測すると登録が失敗し、「止まらない」が偽 PASS になる）。
seed() {
  python3 - "$AIDD_ASYNC_STATE" "$1" "$2" <<'PY'
import json, os, sys, time
state, ident, session = sys.argv[1:4]
json.dump({"id": ident, "kind": "cd-run", "detail": "seed " + ident, "owner": "",
           "check_cmd": "", "source": "manual", "session": session,
           "registered_ts": int(time.time()), "resolved_ts": 0,
           "resolved": False, "conclusion": ""},
          open(os.path.join(state, ident + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# build_skew_cli <out> — --session を解さない台帳 CLI（この変更より前の CLI と同じく unknown flag で拒否する）
build_skew_cli() {
  python3 - "$ASYNC" "$1" <<'PY'
import sys
src, out = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
needle = '      --session) session="${2:-}"; shift 2 ;;\n'
if text.count(needle) not in (0, 2):
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, ""))
PY
}

# skew_cli_ok <cli> — 版ずれ CLI の前提: unresolved は動き、unresolved --session は拒否する
skew_cli_ok() {
  [ -f "$1" ] && bash "$1" unresolved >/dev/null 2>&1 && ! bash "$1" unresolved --session B >/dev/null 2>&1
}

ledger_has() {
  python3 - "$LEDGER" "$1" <<'PY'
import json, os, sys
path, rule = sys.argv[1:3]
if not os.path.exists(path):
    raise SystemExit(1)
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("rule") == rule:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "=== case 1: 持ち越しなし -> 沈黙する（定型文で埋めない） ==="
reset_state c1
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
rc=$?
[[ "$rc" -eq 0 ]] && ok "case1 exit 0" || bad "case1 rc=$rc"
[[ ! -s "$SB/out" ]] \
  && ok "case1 持ち越し 0 件では何も出さない（毎回の定型文は読まれなくなる）" \
  || bad "case1 出力があった: $(cat "$SB/out")"

echo
echo "=== case 2: 未解決の持ち越し -> 冒頭で照合対象を出す（#96 基準3） ==="
reset_state c2
bash "$ASYNC" register --id run-33091489486 --kind cd-run \
  --detail "Alpha CD run 33091489486" >/dev/null
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
rc=$?
[[ "$rc" -eq 0 ]] && ok "case2 exit 0（照合は出すが止めない）" || bad "case2 rc=$rc"
grep -q "run-33091489486" "$SB/out" \
  && ok "case2 持ち越しの id を名指しする" \
  || bad "case2 id が出ない: $(cat "$SB/out")"
grep -q "未宣言" "$SB/out" \
  && ok "case2 owner 未宣言であることを明示する" \
  || bad "case2 owner の状態が出ない"
grep -q "status=in_progress\` は前進の証拠ではない" "$SB/out" \
  && ok "case2 in_progress を前進の根拠にするなと明示する" \
  || bad "case2 in_progress の否認がない"
grep -q "gh run view" "$SB/out" \
  && ok "case2 実行可能な確認コマンドを含む（参照だけで終わらない）" \
  || bad "case2 確認コマンドがない"
ledger_has carryover-reconciled \
  && ok "case2 照合が走ったことを台帳へ measure で残す（実測できる）" \
  || bad "case2 台帳に carryover-reconciled 行がない"

echo
echo "=== case 3: owner 宣言済みでも照合対象には出す（読み返しが目的） ==="
reset_state c3
bash "$ASYNC" register --id run-777 --kind cd-run --detail "Alpha CD" \
  --owner "監督が 09:00 JST に確認" --check-cmd "gh run view 777 --json conclusion" >/dev/null
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
grep -q "監督が 09:00 JST に確認" "$SB/out" \
  && ok "case3 宣言された確認主体をそのまま出す" \
  || bad "case3 owner が出ない"
grep -q "gh run view 777" "$SB/out" \
  && ok "case3 宣言された確認コマンドを出す" \
  || bad "case3 check_cmd が出ない"

echo
echo "=== case 4: resolve 済みは出さない ==="
reset_state c4
bash "$ASYNC" register --id run-555 --kind cd-run --detail "Alpha CD" >/dev/null
bash "$ASYNC" resolve --id run-555 --conclusion failure >/dev/null
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
[[ ! -s "$SB/out" ]] \
  && ok "case4 終端済みは照合対象に出さない" \
  || bad "case4 resolve 済みが出た: $(cat "$SB/out")"

echo
echo "=== case 5: 実セッションを止めない（最優先の性質） ==="
echo "    台帳 CLI 不在 / 台帳破損 / 空入力 のいずれでも exit 0 かつ無害であること。"
ISO="$SB/iso"; mkdir -p "$ISO/hooks/lib"
cp "$HOOK" "$ISO/hooks/aidd-carryover-reconcile.sh"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$ISO/hooks/lib/aidd-ledger.sh"
reset_state c5
run_hook "$ISO/hooks/aidd-carryover-reconcile.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
rc=$?
[[ "$rc" -eq 0 ]] && ok "case5 台帳 CLI 不在でも exit 0" || bad "case5 CLI 不在で rc=$rc"
[[ ! -s "$SB/out" ]] \
  && ok "case5 CLI 不在では何も主張しない（「持ち越し 0」と誤解させない）" \
  || bad "case5 CLI 不在なのに出力した"
grep -q "async-work.sh が見つからない" "$SB/err" \
  && ok "case5 効いていないことは stderr に残す（無言で無効化しない）" \
  || bad "case5 CLI 不在が無言だった"

reset_state c5b
printf 'this is not json\n' >"$AIDD_ASYNC_STATE/broken.json"
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
rc=$?
[[ "$rc" -eq 0 ]] && ok "case5 台帳が壊れていても exit 0" || bad "case5 破損台帳で rc=$rc"

reset_state c5c
printf '' | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME" bash "$HOOK" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "case5 空 stdin でも exit 0" || bad "case5 空 stdin で落ちた (rc=$rc)"

echo
echo "=== case 6: プロンプト本文を読まない・出さない（人間ゲート） ==="
python3 - "$HOOK" <<'PY' && ok "case6 transcript を読む経路を持たない（台帳のみを入力にする）" || bad "case6 transcript を読んでいる"
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for bad_token in ("transcript_path", "projects/", ".jsonl"):
    assert bad_token not in t, "reads transcripts: %s" % bad_token
assert "async-work.sh" in t, "does not read the registry"
PY

echo
echo "=== case 7: テスト実行の登録は次ターン冒頭にも出さない ==="
echo "    濾過は scripts/async-work.sh unresolved の 1 箇所。停止判定と冒頭照合が同時に揃う。"
reset_state c7
bash "$ASYNC" register --id run-test-1 --kind cd-run --detail "test fixture" \
  --source "test:posttooluse-auto" >/dev/null
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
[[ ! -s "$SB/out" ]] \
  && ok "case7 test 系 source は冒頭照合に出さない" \
  || bad "case7 test 登録が冒頭照合に出た: $(cat "$SB/out")"
bash "$ASYNC" register --id run-real-1 --kind cd-run --detail "real carry-over" >/dev/null
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
grep -q "run-real-1" "$SB/out" \
  && ok "case7 本物の持ち越しは従来どおり出す（濾しすぎていない）" \
  || bad "case7 本物まで濾過された"
grep -q "run-test-1" "$SB/out" \
  && bad "case7 test 登録が混ざった" \
  || ok "case7 同時に存在しても test 系だけが除かれる"

echo
echo "=== case 8: 他セッションの持ち越しには「触らない」印を付ける（2026-09-28 の干渉） ==="
echo "    台帳は全セッションで共有。印が無いと、無関係なセッションが他人の持ち越しを resolve / owner 宣言する。"
reset_state c8
seed run-other-8 A
seed run-mine-8 t
run_hook "$HOOK" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
rc=$?
[[ "$rc" -eq 0 ]] && ok "case8 exit 0" || bad "case8 rc=$rc"
grep -q "run-other-8" "$SB/out" && grep -q "run-mine-8" "$SB/out" \
  && ok "case8 自分の分も他セッションの分も照合対象として出す（隠さない）" \
  || bad "case8 どちらかが出ない: $(cat "$SB/out")"
n_label=$(grep -c "登録元: 別セッション（session=A）。このセッションからは resolve / owner 宣言しない" "$SB/out")
[[ "$n_label" -eq 1 ]] \
  && ok "case8 他セッションの分にだけ「触らない」印が 1 件付く" \
  || bad "case8 印の件数が ${n_label}（期待 1）: $(cat "$SB/out")"

echo
echo "=== case 9: 台帳 CLI が --session を知らない版ずれでも沈黙しない ==="
SKEW="$SB/skew"; mkdir -p "$SKEW/hooks/lib" "$SKEW/scripts"
cp "$HOOK" "$SKEW/hooks/aidd-carryover-reconcile.sh"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SKEW/hooks/lib/aidd-ledger.sh"
build_skew_cli "$SKEW/scripts/async-work.sh"
reset_state c9
skew_cli_ok "$SKEW/scripts/async-work.sh" \
  && ok "case9 前提: 版ずれ CLI は unresolved に答え、--session だけを拒否する" \
  || bad "case9 前提: 版ずれ CLI を作れない — 以下は反証にならない"
seed run-skew-9 A
run_hook "$SKEW/hooks/aidd-carryover-reconcile.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
grep -q "run-skew-9" "$SB/out" \
  && ok "case9 版ずれでも持ち越しを出す（「持ち越し 0」と誤解させない）" \
  || bad "case9 版ずれで沈黙した"

echo
echo "=== 変異体: 条件を外すと同じシナリオが黙る／誤って主張する ==="
# 変異体はリポジトリと同じレイアウトへ置く。hooks/ の 1 つ上に scripts/ が無いと hook は台帳 CLI を
# 解決できず沈黙するため、「沈黙する」を期待する変異体が条件を外した効果と無関係に PASS する
# （2026-09-28 まで変異(1) はこの偽 PASS だった）。対照として無変異の写しが持ち越しを出すことを先に確かめる。
MUT="$SB/mut/hooks"; mkdir -p "$MUT" "$SB/mut/scripts"
cp "$ASYNC" "$SB/mut/scripts/async-work.sh"
cp "$HOOK" "$MUT/control.sh"
reset_state m0
seed run-m0 A
run_hook "$MUT/control.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
grep -q "run-m0" "$SB/out" \
  && ok "対照 変異体の配置でも無変異の hook は持ち越しを出す（配置由来の沈黙ではない）" \
  || bad "対照 変異体の配置で台帳 CLI を解決できない — 以下の変異体は反証にならない"
mutate() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, needle, repl, out = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if needle not in t:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(t.replace(needle, repl, 1))
PY
}

# (1) 未解決の抽出を空にする -> case2 が沈黙する
if mutate "$HOOK" 'if ! unresolved="$(bash "$ASYNC_SH" unresolved --session "$session" 2>/dev/null)"; then' \
   'unresolved=""; if false; then' "$MUT/blind.sh"; then
  reset_state m1
  bash "$ASYNC" register --id run-m1 --kind cd-run --detail open >/dev/null
  run_hook "$MUT/blind.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
  [[ ! -s "$SB/out" ]] \
    && ok "変異(台帳読み取り除去) 持ち越しがあっても沈黙する = 読み取りは効いていた" \
    || bad "変異(台帳読み取り除去) 何も変わらない = case2 は別経路が出していた"
else
  bad "変異(台帳読み取り除去) 対象が見つからない — 反証不能"
fi

# (2) CLI 不在時の stderr を外す -> case5 の「無言で無効化しない」が壊れる
if mutate "$HOOK" "  printf '[carryover] scripts/async-work.sh が見つからないため持ち越し照合を省略しました。\\n' >&2" \
   '  :' "$MUT/silent.sh"; then
  ISO2="$SB/iso2"; mkdir -p "$ISO2/hooks/lib"
  cp "$MUT/silent.sh" "$ISO2/hooks/h.sh"
  cp "$ROOT/hooks/lib/aidd-ledger.sh" "$ISO2/hooks/lib/aidd-ledger.sh"
  reset_state m2
  run_hook "$ISO2/hooks/h.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
  [[ ! -s "$SB/err" ]] \
    && ok "変異(不在警告除去) 無言で無効化される = 警告は効いていた" \
    || bad "変異(不在警告除去) それでも警告が出る = case5 は別経路が出していた"
else
  bad "変異(不在警告除去) 対象が見つからない — 反証不能"
fi

# (3) 他セッションの印を外す -> case8 の「触らない」印が消える
if mutate "$HOOK" '    if session and not r.get("mine"):' '    if False:' "$MUT/nolabel.sh"; then
  reset_state m3
  seed run-m3 A
  run_hook "$MUT/nolabel.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
  grep -q "run-m3" "$SB/out" && ! grep -q "登録元: 別セッション" "$SB/out" \
    && ok "変異(他セッション印除去) 他人の持ち越しが無印で出る = 印は効いていた" \
    || bad "変異(他セッション印除去) 何も変わらない = case8 は別経路が出していた"
else
  bad "変異(他セッション印除去) 対象が見つからない — 反証不能"
fi

# (4) 版ずれ時の再照会を外す -> case9 が沈黙する
if mutate "$HOOK" '  unresolved="$(bash "$ASYNC_SH" unresolved 2>/dev/null || true)"' '  unresolved=""' \
   "$SKEW/hooks/nofallback.sh"; then
  reset_state m4
  seed run-m4 A
  run_hook "$SKEW/hooks/nofallback.sh" AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" HOME="$HOME"
  [[ ! -s "$SB/out" ]] \
    && ok "変異(版ずれ時の再照会除去) 版ずれで沈黙する = case9 は再照会が作っていた" \
    || bad "変異(版ずれ時の再照会除去) それでも出る = case9 は別経路が出していた"
else
  bad "変異(版ずれ時の再照会除去) 対象が見つからない — 反証不能"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
