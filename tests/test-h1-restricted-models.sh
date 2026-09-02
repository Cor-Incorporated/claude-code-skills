#!/usr/bin/env bash
# H1 が「どのモデルを止めるか」— 2026-09-02 のインシデントの陰性テスト。
#
# 起点事故: H1 は全モデルに一律 $5 の上限をかけていた。通常の Codex セッションが
# 301 tool call で spend=$5.34 に達して block し、Google Drive の再読込と
# ローカルファイル操作の直前で実作業が停止した。
#
# 原因は 2 つが重なったこと。
#   (1) この機械の Codex は gpt-5.6-luna を動かすが PRICES に無く、unknown-model
#       経路が MAX_RATE（既知で最も高い単価）で見積もる。実測 budget_source:
#       "rollout:total_token_usage+unknown-model:gpt-5.6-luna@max-rate"
#   (2) そもそも全モデルを止める必要が無かった。予算を溶かした実績があるのは
#       最上位モデル（gpt-5.6-sol の ultra）だけである。
#
# 以後 block は CODEX_H1_RESTRICTED_MODELS に一致するモデルでのみ評価する。
# このスイートはその絞り込み自体を検査する。停止規則の中身は
# tests/test-h1-block.sh が（ワイルドカードで全モデルを対象にして）検査する。
#
# 反証可能性: 各主張について、絞り込みを外した変異体を作って結果が変わることを
# 実測する。外して何も変わらないなら、絞り込みは最初から効いていない。
#
# 全ての hook 実行は HOME=$SB / AIDD_LEDGER_SOURCE=test の下で走るので、実際の
# ~/.claude 台帳にも ~/.codex 状態にも触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test
# ここでは既定の絞り込みを検査するので、外側の環境変数を必ず落とす。
unset CODEX_H1_RESTRICTED_MODELS

HOOK="$ROOT/hooks/codex/h1-stall-runtime.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$SB/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/.claude/hooks/lib/aidd-ledger.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

# run <hook> <delegation> <command> [extra env assignments...]
run() {
  local hook="$1" delegation="$2" cmd="$3"
  shift 3
  payload "$cmd" | env HOME="$SB" \
    CODEX_H1_DELEGATION="$delegation" \
    CODEX_H1_SESSIONS_DIR="$SB/sessions" \
    "$@" bash "$hook"
}

decision_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("allow"); raise SystemExit(0)
print(((d.get("hookSpecificOutput") or {}).get("permissionDecision")) or "allow")
'
}

# 同じ消費量を、モデル名だけ変えて与える。差が出るならモデルで絞れている。
seed_rollout() { # $1=model  $2=input_tokens  $3=output_tokens
  rm -rf "$SB/sessions"
  local dir="$SB/sessions/2026/09/01"
  mkdir -p "$dir"
  cat >"$dir/rollout-2026-09-01T00-00-00-fixture.jsonl" <<EOF
{"type":"session_meta","payload":{"model":"$1"}}
{"total_token_usage":{"input_tokens":$2,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":$3,"reasoning_output_tokens":0,"total_tokens":$(($2 + $3))}}
EOF
}

subject_field() { # $1=delegation $2=field
  python3 - "$LEDGER" "$1" "$2" <<'PY'
import json, os, sys
path, delegation, field = sys.argv[1:4]
if not os.path.exists(path):
    print(""); raise SystemExit(0)
val = ""
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("component") != "H1":
        continue
    subject = row.get("subject") or {}
    if subject.get("delegation") != delegation:
        continue
    if field in subject:
        val = subject[field]
print(val)
PY
}

# 上限を確実に超える消費量。4M in + 400k out は MAX_RATE で $9.00。
OVER_IN=4000000
OVER_OUT=400000
BUDGET=5

echo "=== 1. 制限対象外のモデルは、上限を超えていても止めない（今日の事故） ==="
for model in gpt-5.6-luna gpt-5-codex gpt-5.6-terra; do
  seed_rollout "$model" "$OVER_IN" "$OVER_OUT"
  out=$(run "$HOOK" "nr-$model" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET")
  d=$(decision_of "$out")
  if [[ "$d" == "allow" ]]; then
    ok "$model は予算超過でも allow（restricted=$(subject_field "nr-$model" restricted)）"
  else
    bad "$model が止められた（今日の事故の再現）" "decision=$d"
  fi
done

echo
echo "=== 2. 制限対象のモデルは、上限を超えたら止める ==="
for model in gpt-5.6-sol gpt-5.6-sol-ultra; do
  seed_rollout "$model" "$OVER_IN" "$OVER_OUT"
  out=$(run "$HOOK" "r-$model" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET")
  d=$(decision_of "$out")
  if [[ "$d" == "deny" ]]; then
    ok "$model は予算超過で deny（restricted=$(subject_field "r-$model" restricted)）"
  else
    bad "$model が止まらない（暴走の実績があるモデルを素通しした）" "decision=$d"
  fi
done

echo
echo "=== 3. 制限対象でも上限内なら止めない（過剰ブロックしない） ==="
seed_rollout "gpt-5.6-sol-ultra" 100000 1000
out=$(run "$HOOK" "r-under" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET")
[[ "$(decision_of "$out")" == "allow" ]] \
  && ok "sol でも予算内なら allow" \
  || bad "sol を予算内で止めた（過剰ブロック）" "decision=$(decision_of "$out")"

echo
echo "=== 4. モデルを検出できないときは止めない（unknown != 最上位） ==="
rm -rf "$SB/sessions"
out=$(run "$HOOK" "unknown-model" "ls -la" CODEX_H1_BUDGET_USD=0.0000001)
d=$(decision_of "$out")
if [[ "$d" == "allow" ]]; then
  ok "モデル未検出では block しない（proxy 見積で上限を超えていても）"
else
  bad "モデル未検出で止めた（『分からないから止める』が今日の事故の形）" "decision=$d"
fi

echo
echo "=== 5. 台帳に model と restricted が載る（後から監査できる） ==="
seed_rollout "gpt-5.6-sol-ultra" "$OVER_IN" "$OVER_OUT"
run "$HOOK" "led" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET" >/dev/null
m=$(subject_field led model)
r=$(subject_field led restricted)
[[ "$m" == "gpt-5.6-sol-ultra" ]] && ok "台帳 subject.model=$m" || bad "台帳に model が無い" "got=$m"
[[ "$r" == "True" || "$r" == "true" ]] && ok "台帳 subject.restricted=$r" || bad "台帳に restricted が無い" "got=$r"

echo
echo "=== 6. 反証: 絞り込みを外すと 1. の結論が反転するか ==="
# is_restricted を常に True にした変異体。絞り込みが効いているなら、
# 制限対象外だったモデルが deny に変わるはずである。変わらないなら
# 1. の allow はモデル絞り込み以外の理由で出ていたことになる。
MUT="$SB/mutant.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import sys, pathlib
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text()
needle = '''    if "*" in RESTRICTED_MODELS:
        return True'''
assert needle in t, "mutation target not found"
t = t.replace(needle, '''    if True:
        return True''', 1)
pathlib.Path(dst).write_text(t)
PY
if [[ -f "$MUT" ]]; then
  seed_rollout "gpt-5.6-luna" "$OVER_IN" "$OVER_OUT"
  m1=$(run "$MUT" "mut-luna" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET")
  [[ "$(decision_of "$m1")" == "deny" ]] \
    && ok "変異体（絞り込み無効）は gpt-5.6-luna を deny = 絞り込みが結論を作っていた" \
    || bad "変異体でも allow のまま = 1. は絞り込みを証明していない" "decision=$(decision_of "$m1")"
else
  bad "変異体を作れなかった — 反証不能" "mutation target missing"
fi

echo
echo "=== 7. CODEX_H1_RESTRICTED_MODELS で対象を広げられる ==="
seed_rollout "gpt-5.6-luna" "$OVER_IN" "$OVER_OUT"
out=$(run "$HOOK" "widen" "ls -la" CODEX_H1_BUDGET_USD="$BUDGET" CODEX_H1_RESTRICTED_MODELS="sol,luna")
[[ "$(decision_of "$out")" == "deny" ]] \
  && ok "luna を明示的に対象へ加えると deny になる" \
  || bad "対象を広げても止まらない" "decision=$(decision_of "$out")"

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
