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
if [[ "$s" == "11" ]]; then ok "skipped == 11"; else bad "skipped == 11 (got '$s')"; fi
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
if [[ "$ms" == "0" && "$mp" == "16" ]]; then
  ok "mutant over-claims (passed=16, skipped=0) — the state #349 reported"
else
  bad "mutant did not reproduce the over-claim (passed=$mp skipped=$ms)"
fi
if [[ "$mleak" -ge 10 ]]; then
  ok "this checker detects the mutation ($mleak PASS lines report a skip -> section 3 would go red)"
else
  bad "this checker would NOT detect the mutation — it is not a device"
fi

echo "--- 8. 会計の網羅: implemented == emitted（#351 で NOTE から FAIL へ格上げ） ---"
# #349 では観測だけだった。無言の pair は skip 誤計上より重い（skip は行が出る）。
# 格上げすると、次に無言の pair が入った時点で落ちる。
HOME="$EMPTY" bash "$TARGET" >"$OUT" 2>&1
emitted=$(grep -oE '^(PASS|SKIP|FAIL): pair[0-9]+' "$OUT" | sed 's/.*: //' | sort -u | wc -l | tr -d ' ')
implemented=$(grep -oE '"pair[0-9]+' "$TARGET" | sort -u | wc -l | tr -d ' ')
if [[ "$emitted" == "$implemented" ]]; then
  ok "implemented == emitted (both $implemented) — no pair is silent"
else
  missing=$(comm -13 \
    <(grep -oE '^(PASS|SKIP|FAIL): pair[0-9]+' "$OUT" | sed 's/.*: //' | sort -u) \
    <(grep -oE '"pair[0-9]+' "$TARGET" | tr -d '"' | sort -u) | tr '\n' ' ')
  bad "implemented=$implemented emitted=$emitted — silent pair(s): $missing"
fi

echo "--- 9. 構造照合: 分岐の片側だけが pair を出す形が残っていないこと（#351 の本体） ---"
# 節 8 は「その環境で出たか」しか見ない。pair5 のようにガードが repo ファイルの
# 存在で、現行 2 環境ではどちらも成立する pair は経験的照合に現れない。
# 実測（#351 起点調査）: 経験的には pair2 の 1 件だが、構造的には pair5 も同型だった。
# したがって AST で「body が pair を出すのに orelse が出さない if」を機械照合する。
run_struct() { PAIRS_FILE="$1" python3 "$ROOT/tests/lib/pairs-branch-audit.py"; }
struct_out=$(run_struct "$TARGET")
struct_rc=$?
if [[ "$struct_rc" -ne 0 ]]; then
  bad "structural check could not run (rc=$struct_rc) — not treating as pass"
  printf '      %s\n' "$struct_out"
else
  holes=$(printf '%s' "$struct_out" | sed -nE 's/^COUNT ([0-9]+)$/\1/p')
  if [[ "$holes" == "0" ]]; then
    ok "no branch emits a pair on one side only"
  else
    bad "$holes branch(es) emit a pair on one side only"
    printf '%s\n' "$struct_out" | grep '^HOLE' | sed 's/^/      /'
  fi
fi

echo "--- 10. 節 8/9 自身の反証: pair2 の else を消す片側変異 ---"
# else を消すと pair2 は無言に戻る。節 8（経験的）と節 9（構造）の**両方**が
# それを検出できなければ、格上げは効いていない。
if ! python3 "$ROOT/tests/lib/pairs-mutate-drop-else.py" "$TARGET" "$MUTANT"; then
  bad "mutation could not be injected — fix the injection, not the test"
else
  HOME="$EMPTY" bash "$MUTANT" >"$OUT" 2>&1
  me=$(grep -oE '^(PASS|SKIP|FAIL): pair[0-9]+' "$OUT" | sed 's/.*: //' | sort -u | wc -l | tr -d ' ')
  mi=$(grep -oE '"pair[0-9]+' "$MUTANT" | sort -u | wc -l | tr -d ' ')
  if [[ "$me" -lt "$mi" ]]; then
    ok "section 8 detects the mutation (implemented=$mi emitted=$me -> would go red)"
  else
    bad "section 8 would NOT detect the mutation (implemented=$mi emitted=$me)"
  fi
  mstruct=$(run_struct "$MUTANT")
  mholes=$(printf '%s' "$mstruct" | sed -nE 's/^COUNT ([0-9]+)$/\1/p')
  if [[ "${mholes:-0}" -ge 1 ]]; then
    ok "section 9 detects the mutation ($mholes structural hole(s) -> would go red)"
  else
    bad "section 9 would NOT detect the mutation (holes=${mholes:-parse-failed})"
  fi
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
