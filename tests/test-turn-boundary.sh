#!/usr/bin/env bash
# ターン境界の持ち越し検査 — hooks/aidd-turn-boundary-stop.sh /
# hooks/aidd-async-register.sh / scripts/async-work.sh の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#96 / #95
#
# 起点事故 (2026-08-27): 監督は Alpha CD run 33091489486 が in_progress
# (success=17/25 step) の状態で「進んでいる」と報告してターンを終えた。11 分後に
# CD は失敗し、ユーザーが翌朝指摘するまで 7 時間 25 分だれも気づかなかった。
# 同日、レーン 12 本が正常終了したが空いた枠は補充されず、ユーザーが 5 回以上
# 指摘した。
#
# 本スイートが実測するのは「持ち越しがある状態で停止しようとしたら止まるか」
# であって「無人区間を検知できるか」ではない。後者は Stop hook では原理的に
# 不可能であり、テストでもそう主張しない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOP_HOOK="$ROOT/hooks/aidd-turn-boundary-stop.sh"
REG_HOOK="$ROOT/hooks/aidd-async-register.sh"
ASYNC="$ROOT/scripts/async-work.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
export HOME="$SB/home"
mkdir -p "$HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

reset_state() {
  export AIDD_ASYNC_STATE="$SB/aw-$1"
  rm -rf "$AIDD_ASYNC_STATE"
  mkdir -p "$AIDD_ASYNC_STATE"
}

# stop_payload <stop_hook_active>
stop_payload() {
  python3 -c 'import json,sys; print(json.dumps({"stop_hook_active": sys.argv[1]=="true","session_id":"t"}))' "$1"
}

# run_stop <hook> <stop_hook_active> [env...] -> rc、stderr は $SB/stop.err へ
run_stop() {
  local hook="$1" active="$2"
  shift 2
  stop_payload "$active" | env "$@" bash "$hook" 2>"$SB/stop.err"
}

ledger_has() {
  python3 - "$LEDGER" "$1" "$2" <<'PY'
import json, os, sys
path, rule, event = sys.argv[1:4]
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
    if row.get("rule") == rule and row.get("event") == event:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "=== case 1: 持ち越しなし -> 停止を許す（恒真 block ではない） ==="
reset_state c1
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case1 持ち越しゼロなら素通しする"
else
  bad "case1 持ち越しゼロなのに停止を拒否した (rc=$?)"
fi

echo
echo "=== case 2: 未完了 + owner 未宣言 -> 停止を拒否 (#96 replay) ==="
reset_state c2
bash "$ASYNC" register --id run-33091489486 --kind cd-run \
  --detail "Alpha CD run 33091489486 (in_progress で報告した対象)" >/dev/null
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case2 exit 2 で停止を拒否した" \
  || bad "case2 期待 exit 2, 実際 rc=$rc"
grep -q "run-33091489486" "$SB/stop.err" \
  && ok "case2 拒否理由が対象の run id を名指しする" \
  || bad "case2 拒否理由に run id がない: $(cat "$SB/stop.err")"
grep -q "status=in_progress は前進の証拠ではない" "$SB/stop.err" \
  && ok "case2 拒否理由が in_progress を前進の根拠にするなと明示する" \
  || bad "case2 拒否理由に in_progress の否認がない"
grep -q "gh run view" "$SB/stop.err" \
  && ok "case2 拒否理由が実行可能な確認コマンドを含む（参照だけで終わらない）" \
  || bad "case2 拒否理由に確認コマンドがない"
ledger_has turn-boundary-unresolved block \
  && ok "case2 台帳に rule=turn-boundary-unresolved event=block 行" \
  || bad "case2 台帳に block 行がない"

echo
echo "=== case 3: stop_hook_active=true -> 必ず素通し（無限ループ防止） ==="
reset_state c3
bash "$ASYNC" register --id run-999 --kind cd-run --detail "still open" >/dev/null
if run_stop "$STOP_HOOK" true AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case3 継続中は持ち越しがあっても素通しする"
else
  bad "case3 継続中に再度拒否した = 停止不能になる"
fi

echo
echo "=== case 4: owner を宣言した持ち越し -> 素通しするが記録は残す ==="
reset_state c4
bash "$ASYNC" register --id run-777 --kind cd-run --detail "Alpha CD" \
  --owner "監督が 2026-08-28 09:00 JST に確認" \
  --check-cmd "gh run view 777 --json conclusion" >/dev/null
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case4 確認主体を宣言すれば終えられる（非同期作業の禁止ではない）"
else
  bad "case4 owner 宣言済みなのに拒否した"
fi
ledger_has async-work-owned warn \
  && ok "case4 宣言済み持ち越しが warn として台帳に残る" \
  || bad "case4 宣言済み持ち越しが記録されない"

echo
echo "=== case 5: resolve 済み -> 素通し ==="
reset_state c5
bash "$ASYNC" register --id run-555 --kind cd-run --detail "Alpha CD" >/dev/null
bash "$ASYNC" resolve --id run-555 --conclusion failure >/dev/null
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
  ok "case5 conclusion を読んで終端すれば終えられる"
else
  bad "case5 resolve 済みなのに拒否した"
fi

echo
echo "=== case 6: resolve は非終端の status を終端として受け付けない (#96 要求2) ==="
reset_state c6
bash "$ASYNC" register --id run-666 --kind cd-run --detail "Alpha CD" >/dev/null
for word in in_progress queued running pending IN_PROGRESS; do
  if bash "$ASYNC" resolve --id run-666 --conclusion "$word" >/dev/null 2>&1; then
    bad "case6 conclusion=$word が終端として通った"
  else
    ok "case6 conclusion=$word を拒否した"
  fi
done
if bash "$ASYNC" resolve --id run-666 --conclusion success >/dev/null 2>&1; then
  ok "case6 conclusion=success は通る（恒真 red ではない）"
else
  bad "case6 正当な conclusion まで拒否した"
fi

echo
echo "=== case 7 (#95): 目標並列度を下回ったままターンを終えない ==="
reset_state c7
bash "$ASYNC" register --id lane-1 --kind lane --detail "issue #2004" \
  --owner "codex-parallel" >/dev/null
bash "$ASYNC" register --id lane-2 --kind lane --detail "issue #2007" \
  --owner "codex-parallel" >/dev/null
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LANE_TARGET=8
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case7 稼働 2 / 目標 8 で停止を拒否した" \
  || bad "case7 レーン欠員を素通しした (rc=$rc)"
grep -q "枠が空いた" "$SB/stop.err" \
  && ok "case7 拒否理由が「完了 = 成果回収 + 枠が空いた」の 2 事実を述べる" \
  || bad "case7 拒否理由に補充の指示がない"
reset_state c7b
for i in 1 2 3 4 5 6 7 8; do
  bash "$ASYNC" register --id "lane-$i" --kind lane --detail "task $i" --owner cp >/dev/null
done
if run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" AIDD_LANE_TARGET=8; then
  ok "case7 目標に達していれば素通しする（恒真 block ではない）"
else
  bad "case7 目標充足なのに拒否した"
fi

echo
echo "=== case 8: PostToolUse 自動登録 — gh workflow run / nohup ==="
reset_state c8
post_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}
post_payload 'gh workflow run v2-alpha-cd.yml --ref develop' \
  | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -ge 1 ]] \
  && ok "case8 gh workflow run が自動登録された（監督が忘れても登録される）" \
  || bad "case8 gh workflow run が登録されない"
run_stop "$STOP_HOOK" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
[[ "$?" -eq 2 ]] \
  && ok "case8 自動登録された持ち越しでターン終了が止まる" \
  || bad "case8 自動登録後もターンを終えられた"

reset_state c8b
post_payload 'nohup ./scripts/fire-cd.sh > /tmp/fire.log 2>&1 &' \
  | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -ge 1 ]] \
  && ok "case8 nohup が自動登録された（#96 の起点コマンド形）" \
  || bad "case8 nohup が登録されない"

echo
echo "=== case 9: 誤検知しない — 読み取り専用コマンドは登録しない ==="
reset_state c9
for c in 'git status' 'ls -la' 'gh run view 123 --json conclusion' 'grep -rn TODO src/'; do
  post_payload "$c" | env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$REG_HOOK" >/dev/null 2>&1
done
n=$(bash "$ASYNC" unresolved | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$n" -eq 0 ]] \
  && ok "case9 読み取り専用 4 種は 1 件も登録しない（ターン終了を無駄に止めない）" \
  || bad "case9 誤検知 $n 件"

echo
echo "=== 変異体: 条件を外すと同じシナリオが素通しすることの実測 ==="
# 変異体はリポジトリと同じレイアウトへ置く。hooks/ の 1 つ上に scripts/ が無いと
# hook は台帳 CLI を解決できず exit 0 で素通しするため、条件を外した効果ではなく
# 「台帳が無いから通った」だけの偽 PASS になる。
MUT="$SB/mutants/hooks"
mkdir -p "$MUT" "$SB/mutants/scripts"
cp "$ASYNC" "$SB/mutants/scripts/async-work.sh"
mutate() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, needle, replacement, out = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if needle not in text:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, replacement, 1))
PY
}

if mutate "$STOP_HOOK" 'unowned = [r for r in rows if not r.get("owned")]' \
      'unowned = []' "$MUT/nounowned.sh"; then
  reset_state m1
  bash "$ASYNC" register --id run-m1 --kind cd-run --detail "open" >/dev/null
  if run_stop "$MUT/nounowned.sh" false AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"; then
    ok "変異(未宣言持ち越し判定除去) case2 が素通しする = 判定は効いていた"
  else
    bad "変異(未宣言持ち越し判定除去) それでも拒否 = case2 は別条件が出している"
  fi
else
  bad "変異(未宣言持ち越し判定除去) 対象が見つからない — 反証不能"
fi

if mutate "$STOP_HOOK" 'if [ "$active" = "true" ]; then' 'if false; then' "$MUT/noguard.sh"; then
  reset_state m2
  bash "$ASYNC" register --id run-m2 --kind cd-run --detail "open" >/dev/null
  run_stop "$MUT/noguard.sh" true AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE"
  [[ "$?" -eq 2 ]] \
    && ok "変異(stop_hook_active ガード除去) 継続中も拒否する = ガードは効いていた" \
    || bad "変異(stop_hook_active ガード除去) 何も変わらない = 無限ループ防止が無い"
else
  bad "変異(stop_hook_active ガード除去) 対象が見つからない — 反証不能"
fi

if mutate "$ASYNC" 'for word in $NON_TERMINAL; do' 'for word in ; do' "$MUT/noterm.sh"; then
  reset_state m3
  env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$ASYNC" register --id run-m3 --kind cd-run --detail o >/dev/null
  if env AIDD_ASYNC_STATE="$AIDD_ASYNC_STATE" bash "$MUT/noterm.sh" resolve --id run-m3 --conclusion in_progress >/dev/null 2>&1; then
    ok "変異(非終端語リスト除去) in_progress が終端として通る = リストは効いていた"
  else
    bad "変異(非終端語リスト除去) それでも拒否 = case6 は別条件が出している"
  fi
else
  bad "変異(非終端語リスト除去) 対象が見つからない — 反証不能"
fi

echo
echo "=== 適用限界の明示: この装置はターン終了後の無人区間を検知しない ==="
python3 - "$STOP_HOOK" <<'PY' && ok "限界 hook 本体に「Stop hook では代替できない」と明記されている" || bad "限界 未記載（daemon 不要と読めてしまう）"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "常駐 daemon" in text, "no daemon limitation note"
assert "Stop hook では原理的に代替できない" in text, "limitation not stated as principled"
PY

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
