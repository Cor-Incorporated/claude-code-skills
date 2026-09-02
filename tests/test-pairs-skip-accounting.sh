#!/usr/bin/env bash
# skip を PASS に数えないことの検査（#349）
#
# なぜ別ファイルなのか: #349 は「exit の意味を変えない」ため、表示だけを直しても
# 変異（skip() を ok() に戻す）で黙って元へ戻せてしまう。3 値の集計そのものを
# assert する側が無いと、修正が保持されない。
#
# 最後の節で**この検査器自身を反証する**。skip→ok の変異を注入したコピーを走らせ、
# 本検査がそれを検出できることを実測する。検出できない検査器は装置ではない。
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/tests/test-pairs-link.sh"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

EMPTY=$(mktemp -d)
OUT=$(mktemp)
MUTANT="$ROOT/tests/.pairs-mutant-$$.sh"   # dot 始まりなので CI の tests/test-*.sh に拾われない
trap 'rm -rf "$EMPTY" "$OUT" "$MUTANT"' EXIT

# 集計行 `--- N passed, M skipped, K failed ---` から 3 値を取る
field() { # $1=file $2=passed|skipped|failed
  sed -nE 's/^--- ([0-9]+) passed, ([0-9]+) skipped, ([0-9]+) failed ---$/\1 \2 \3/p' "$1" \
    | head -1 | awk -v k="$2" '{print (k=="passed")?$1:((k=="skipped")?$2:$3)}'
}

echo "=== pair skip accounting (#349) ==="

echo "--- 1. 集計行が 3 値であること ---"
HOME="$EMPTY" bash "$TARGET" >"$OUT" 2>&1
rc_empty=$?
if grep -qE '^--- [0-9]+ passed, [0-9]+ skipped, [0-9]+ failed ---$' "$OUT"; then
  ok "summary is 3-value ($(grep -E '^--- .* ---$' "$OUT" | head -1))"
else
  bad "summary is not 3-value: $(grep -E '^--- ' "$OUT" | head -1)"
fi

echo "--- 2. CI 相当（配備先なし）の実測 ---"
p=$(field "$OUT" passed); s=$(field "$OUT" skipped); f=$(field "$OUT" failed)
if [[ "$p" == "5" ]]; then ok "passed == 5 (CI verifies 5 pairs, not 15)"; else bad "passed == 5 (got '$p')"; fi
if [[ "$s" == "10" ]]; then ok "skipped == 10"; else bad "skipped == 10 (got '$s')"; fi
if [[ "$f" == "0" ]]; then ok "failed == 0"; else bad "failed == 0 (got '$f')"; fi

echo "--- 3. skip が PASS 行に混ざらないこと（本 issue の核心） ---"
leaked=$(grep -c '^PASS: .*skip' "$OUT" || true)
if [[ "$leaked" == "0" ]]; then
  ok "no PASS line reports a skip"
else
  bad "$leaked PASS line(s) still report a skip"
  grep '^PASS: .*skip' "$OUT" | sed 's/^/      /'
fi
skip_lines=$(grep -c '^SKIP: ' "$OUT" || true)
if [[ "$skip_lines" == "$s" ]]; then
  ok "SKIP: lines ($skip_lines) == skipped count"
else
  bad "SKIP: lines ($skip_lines) != skipped count ($s)"
fi

echo "--- 4. skip の理由が 1 行ずつ出ること ---"
reasons=$(sed -n '/^--- skipped (/,$p' "$OUT" | grep -c '^  SKIP: ' || true)
if [[ "$reasons" == "$s" ]]; then
  ok "reason block lists all $s skipped pairs"
else
  bad "reason block lists $reasons of $s skipped pairs"
fi
if sed -n '/^--- skipped (/,$p' "$OUT" | grep -q 'no local deploy'; then
  ok "existing reason strings are preserved"
else
  bad "reason strings were lost"
fi

echo "--- 5. exit の意味は変えない ---"
if [[ "$rc_empty" == "0" ]]; then
  ok "skipped>0 with failed==0 still exits 0 (rc=$rc_empty)"
else
  bad "exit changed: rc=$rc_empty with failed==0"
fi

echo "--- 6. 配備済み環境の実測 ---"
# CI ランナーは配備先を持たないので、ここを無条件に assert すると CI が赤くなる。
# 「配備済みか」は pair1 自身の条件（~/.claude/hooks/*.sh の存在）で判定する。
# 配備されていない環境では assert せず、測っていないことを明示する。
deployed=0
for _h in "$HOME"/.claude/hooks/*.sh; do
  [[ -f "$_h" ]] && deployed=1 && break
done
if [[ "$deployed" -eq 0 ]]; then
  echo "  NOTE: this environment has no deployed hooks — the deployed-environment"
  echo "  NOTE: assertion is not measurable here (CI runner). Measured on a deployed"
  echo "  NOTE: machine instead; the value is recorded in the PR body."
else
  bash "$TARGET" >"$OUT" 2>&1
  rc_dep=$?
  pd=$(field "$OUT" passed); sd=$(field "$OUT" skipped)
  if [[ -z "$pd" ]]; then
    bad "deployed run produced no 3-value summary"
  elif [[ "$sd" == "0" && "$pd" -ge 15 ]]; then
    ok "deployed: passed=$pd (>=15), skipped=0, rc=$rc_dep"
  else
    bad "deployed: passed=$pd skipped=$sd (want skipped=0, passed>=15)"
  fi
fi

echo "--- 7. 検査器自身の反証: skip() を ok() に戻す片側変異 ---"
sed 's/^\( *\)skip("pair/\1ok("pair/' "$TARGET" >"$MUTANT"
mutated=$(grep -c '^ *ok("pair[0-9]*[^"]*skipped' "$MUTANT" || true)
if [[ "$mutated" -ge 10 ]]; then
  ok "mutation injected ($mutated skip sites reverted to ok)"
else
  bad "mutation did not apply (only $mutated sites) — the sed target moved; fix the injection, not the test"
fi
HOME="$EMPTY" bash "$MUTANT" >"$OUT" 2>&1
mp=$(field "$OUT" passed); ms=$(field "$OUT" skipped)
mleak=$(grep -c '^PASS: .*skip' "$OUT" || true)
if [[ "$ms" == "0" && "$mp" == "15" ]]; then
  ok "mutant over-claims (passed=15, skipped=0) — exactly the state #349 reports"
else
  bad "mutant did not reproduce the over-claim (passed=$mp skipped=$ms)"
fi
if [[ "$mleak" -ge 10 ]]; then
  ok "this checker detects the mutation ($mleak PASS lines report a skip -> section 3 would go red)"
else
  bad "this checker would NOT detect the mutation — it is not a device"
fi

echo "--- 8. 会計の網羅（非失敗の観測。#349 の範囲外の欠陥を隠さないため） ---"
HOME="$EMPTY" bash "$TARGET" >"$OUT" 2>&1
emitted=$(grep -oE '^(PASS|SKIP|FAIL): pair[0-9]+' "$OUT" | sed 's/.*: //' | sort -u | wc -l | tr -d ' ')
implemented=$(grep -oE '"pair[0-9]+' "$TARGET" | sort -u | wc -l | tr -d ' ')
echo "  NOTE: implemented=$implemented emitted=$emitted"
if [[ "$emitted" != "$implemented" ]]; then
  missing=$(comm -13 \
    <(grep -oE '^(PASS|SKIP|FAIL): pair[0-9]+' "$OUT" | sed 's/.*: //' | sort -u) \
    <(grep -oE '"pair[0-9]+' "$TARGET" | tr -d '"' | sort -u) | tr '\n' ' ')
  echo "  NOTE: これらの pair は PASS/SKIP/FAIL のどれも出していない: $missing"
  echo "  NOTE: 無言で何も出さないのは skip 誤計上より重い。#349 の 7 項目の外なので"
  echo "  NOTE: ここでは失敗にせず観測だけ記録する（別 issue の対象）。"
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
