#!/usr/bin/env bash
# セッション記録スキャナ — scripts/turn-carryover-scan.py の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#96 受入基準 (1)(2)
#
# 受入基準 (1) は「回数が **0 であることを示せる**」ことを要求している。
# したがって次の 2 つを両方実測しないと意味がない。
#   (a) 本物の持ち越しを検出する    — 0 が空虚な 0 でないこと
#   (b) 偽陽性を出さない            — 0 を示せること
# 素朴な部分一致は (b) で落ちる。実測: 監督セッション 1 本に 5 件ヒットし全て偽陽性。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/scripts/turn-carryover-scan.py"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# mk_transcript <out> — 引数で与えた行を jsonl として書く。
# 形式は Claude Code のセッション記録に合わせる。
py_mk() {
  python3 - "$@" <<'PY'
import json, sys
out = sys.argv[1]
rows = []
def human(ts):
    return {"type": "user", "timestamp": ts,
            "message": {"role": "user", "content": "next task"}}
def tool(ts, cmd):
    return {"type": "assistant", "timestamp": ts,
            "message": {"role": "assistant", "content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}}
def text(ts, body):
    return {"type": "assistant", "timestamp": ts,
            "message": {"role": "assistant", "content": [
                {"type": "text", "text": body}]}}
def result(ts):
    return {"type": "user", "timestamp": ts,
            "message": {"role": "user", "content": [
                {"type": "tool_result", "content": "ok"}]}}
spec = json.loads(sys.argv[2])
for kind, ts, payload in spec:
    rows.append({"human": human, "tool": tool, "text": text,
                 "result": result}[kind](ts, payload) if kind != "human"
                and kind != "result" else
                {"human": human, "result": result}[kind](ts))
with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

scan() { python3 "$SCAN" --file "$1" --json "${@:2}"; }
field() { printf '%s' "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }

echo "=== case 1: 本物の持ち越しを検出する（0 が空虚でないこと） ==="
T="$SB/carry.jsonl"
py_mk "$T" '[["human","2026-08-27T15:00:00Z",null],
             ["tool","2026-08-27T15:01:00Z","gh workflow run v2-alpha-cd.yml --ref develop"],
             ["result","2026-08-27T15:02:00Z",null],
             ["human","2026-08-27T23:42:00Z",null],
             ["tool","2026-08-27T23:43:00Z","git status"]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "1" ]] \
  && ok "case1 起動して終端せずに終えたターンを 1 件検出" \
  || bad "case1 期待 1, 実際 $(field "$OUT" turns_ended_with_unresolved_async)"

echo
echo "=== case 2: 終端したターンは数えない ==="
T="$SB/resolved.jsonl"
py_mk "$T" '[["human","2026-08-27T15:00:00Z",null],
             ["tool","2026-08-27T15:01:00Z","gh workflow run v2-alpha-cd.yml --ref develop"],
             ["tool","2026-08-27T15:20:00Z","gh run view 33091489486 --json status,conclusion"],
             ["human","2026-08-27T16:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "0" ]] \
  && ok "case2 conclusion を読んだターンは持ち越しに数えない" \
  || bad "case2 期待 0, 実際 $(field "$OUT" turns_ended_with_unresolved_async)"

echo
echo "=== case 3: status だけの読み出しは終端の証拠にしない（#96 の核心） ==="
T="$SB/statusonly.jsonl"
py_mk "$T" '[["human","2026-08-27T15:00:00Z",null],
             ["tool","2026-08-27T15:01:00Z","gh workflow run v2-alpha-cd.yml --ref develop"],
             ["tool","2026-08-27T15:20:00Z","gh run view 33091489486 --json status"],
             ["human","2026-08-27T16:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "1" ]] \
  && ok "case3 status だけ見て終えたターンは持ち越しのまま" \
  || bad "case3 status 読みを終端と誤認した"

echo
echo "=== case 4: 偽陽性を出さない — 引用・データ文脈・heredoc 散文 ==="
echo "    実測: 監督セッション 1 本に素朴な部分一致が 5 件、うち実際の起動 0 件。"
T="$SB/quoted.jsonl"
py_mk "$T" '[["human","2026-09-02T10:00:00Z",null],
             ["tool","2026-09-02T10:01:00Z","grep -rn \"gh workflow run\" docs/"],
             ["tool","2026-09-02T10:02:00Z","echo \"nohup ./fire-cd.sh &\""],
             ["tool","2026-09-02T10:03:00Z","printf %s \"gh run watch 123\""],
             ["human","2026-09-02T11:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "0" ]] \
  && ok "case4 grep/echo/printf の引数は起動に数えない" \
  || bad "case4 引用で誤検出した: $(field "$OUT" turns_ended_with_unresolved_async)"

T="$SB/heredoc.jsonl"
py_mk "$T" '[["human","2026-09-02T10:00:00Z",null],
             ["tool","2026-09-02T10:01:00Z","git commit -F - <<EOF\nfeat(async): 自動登録を足す\nnohup を自動登録する。台帳を思い出したら書く運用にすると再現する。\nEOF"],
             ["human","2026-09-02T11:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "0" ]] \
  && ok "case4 git commit の heredoc 本文（散文）は起動に数えない" \
  || bad "case4 heredoc 散文で誤検出した"
# 本文の 2 行目は行頭が nohup。2026-09-02 の実測で偽陽性になった形そのもの。

echo
echo "--- ただしインタプリタの heredoc 本文は落とさない（見落とし防止） ---"
T="$SB/interp.jsonl"
py_mk "$T" '[["human","2026-09-02T10:00:00Z",null],
             ["tool","2026-09-02T10:01:00Z","bash - <<EOF\ngh workflow run real.yml\nEOF"],
             ["human","2026-09-02T11:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "1" ]] \
  && ok "case4 インタプリタ heredoc 内の実起動は見落とさない" \
  || bad "case4 インタプリタ heredoc 内の起動を落とした"

echo
echo "=== case 5 (#96 基準2): in_progress を前進と報告した箇所 ==="
T="$SB/claims.jsonl"
py_mk "$T" '[["human","2026-08-27T15:00:00Z",null],
             ["text","2026-08-27T15:05:00Z","CD は status=in_progress で success=17/25 step まで進んでいるので順調です。"],
             ["human","2026-08-27T16:00:00Z",null]]'
OUT="$(scan "$T" --report-text)"
[[ "$(field "$OUT" in_progress_progress_claims)" == "1" ]] \
  && ok "case5 in_progress を根拠に「進んでいる/順調」と述べた箇所を検出" \
  || bad "case5 期待 1, 実際 $(field "$OUT" in_progress_progress_claims)"

T="$SB/noclaim.jsonl"
py_mk "$T" '[["human","2026-08-27T15:00:00Z",null],
             ["text","2026-08-27T15:05:00Z","CD は in_progress です。conclusion を読むまで前進とは扱いません。"],
             ["human","2026-08-27T16:00:00Z",null]]'
OUT="$(scan "$T" --report-text)"
[[ "$(field "$OUT" in_progress_progress_claims)" == "0" ]] \
  && ok "case5 conclusion に言及していれば数えない（恒真 red ではない）" \
  || bad "case5 正しい報告まで数えた"

echo
echo "=== case 6: 出力に本文を含めない（人間ゲート） ==="
T="$SB/secret.jsonl"
py_mk "$T" '[["human","2026-09-02T10:00:00Z",null],
             ["tool","2026-09-02T10:01:00Z","gh workflow run x.yml"],
             ["text","2026-09-02T10:02:00Z","ここには長いプロンプト本文と機微な文字列 SUPERSECRETVALUE が入る"],
             ["human","2026-09-02T11:00:00Z",null]]'
OUT="$(scan "$T" --report-text)"
if printf '%s' "$OUT" | grep -q "SUPERSECRETVALUE"; then
  bad "case6 本文が出力に漏れた"
else
  ok "case6 前進主張に該当しない本文は出力に現れない"
fi
python3 - "$SCAN" <<'PY' && ok "case6 出力に載るのは件数・id・断片のみ（設計上の宣言）" || bad "case6 本文を出す経路がある"
import sys
t = open(sys.argv[1], encoding="utf-8").read()
assert "件数と id" in t or "件数と" in t, "no stated limit"
PY

echo
echo "=== case 7: 実データで 0 を示せる（基準1 の「0 件であることを示せる」） ==="
REAL="$(find "$HOME/.claude/projects" -name '*.jsonl' -newermt '2026-09-01' 2>/dev/null | head -1)"
if [ -n "$REAL" ]; then
  OUT="$(scan "$REAL")"
  T_N="$(field "$OUT" turns)"
  C_N="$(field "$OUT" turns_ended_with_unresolved_async)"
  [[ "$T_N" -gt 0 ]] \
    && ok "case7 実セッションからターンを抽出できた（$T_N ターン）" \
    || bad "case7 実データでターンが 0 = 抽出が効いていない"
  echo "    実データの持ち越しターン数: $C_N"
else
  echo "SKIP: 実セッション記録が無い環境（CI では正常）"
fi

echo
echo "=== 変異体: 判定を外すと偽陽性が戻る／検出が消える ==="
MUT="$SB/mut"; mkdir -p "$MUT"
mutate() {
  python3 - "$SCAN" "$1" "$2" "$3" <<'PY'
import sys
src, needle, repl, out = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if needle not in t:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(t.replace(needle, repl, 1))
PY
}
scan_with() { python3 "$1" --file "$2" --json "${@:3}"; }

# (1) heredoc 除去を外す -> git commit の散文が起動に見える
if mutate 'strip_heredoc_bodies(cmd)' 'cmd' "$MUT/noheredoc.py"; then
  OUT="$(scan_with "$MUT/noheredoc.py" "$SB/heredoc.jsonl")"
  [[ "$(field "$OUT" turns_ended_with_unresolved_async)" != "0" ]] \
    && ok "変異(heredoc 除去なし) commit 散文が起動に見える = 除去は効いていた" \
    || bad "変異(heredoc 除去なし) 何も変わらない = case4 は別条件が出していた"
else
  bad "変異(heredoc 除去なし) 対象が見つからない — 反証不能"
fi

# (2) データ文脈の除外を外す -> 引用された resolve が「終端した」に見える
# launches_in 側では toks[i] が gh/nohup でない限り一致しないので冗長だが、
# resolutions_in 側では load-bearing である（引用が終端の偽証拠になる）。
T="$SB/quotedresolve.jsonl"
py_mk "$T" '[["human","2026-09-02T10:00:00Z",null],
             ["tool","2026-09-02T10:01:00Z","gh workflow run x.yml"],
             ["tool","2026-09-02T10:02:00Z","echo \"async-work.sh resolve --id x\""],
             ["human","2026-09-02T11:00:00Z",null]]'
OUT="$(scan "$T")"
[[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "1" ]] \
  && ok "引用された resolve は終端の証拠に数えない" \
  || bad "引用された resolve を終端と誤認した"
if mutate 'if i >= len(toks) or toks[i] in DATA_ONLY:
            continue
        joined' 'if i >= len(toks):
            continue
        joined' "$MUT/nodata.py"; then
  OUT="$(scan_with "$MUT/nodata.py" "$SB/quotedresolve.jsonl")"
  [[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "0" ]] \
    && ok "変異(データ文脈除外なし) 引用 resolve が終端に見える = 除外は効いていた" \
    || bad "変異(データ文脈除外なし) 何も変わらない"
else
  bad "変異(データ文脈除外なし) 対象が見つからない — 反証不能"
fi

# (3) conclusion 要求を外す -> status だけで終端扱いになる
if mutate '"conclusion" in joined' '"status" in joined' "$MUT/nocheck.py"; then
  OUT="$(scan_with "$MUT/nocheck.py" "$SB/statusonly.jsonl")"
  [[ "$(field "$OUT" turns_ended_with_unresolved_async)" == "0" ]] \
    && ok "変異(conclusion 要求なし) status だけで終端扱いになる = 要求は効いていた" \
    || bad "変異(conclusion 要求なし) 何も変わらない = case3 は別条件が出していた"
else
  bad "変異(conclusion 要求なし) 対象が見つからない — 反証不能"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
