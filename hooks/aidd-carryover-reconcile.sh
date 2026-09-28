#!/usr/bin/env bash
# SessionStart: 未完了の非同期作業を次ターン冒頭で照合する.
#
# Issue: Cor-Incorporated/aidd-governance#96 受入基準 (3)
#   「未完了作業の持ち越し台帳が存在し、**次ターン冒頭の照合が実測できる**」
#
# 台帳（scripts/async-work.sh）と Stop 側の関門（aidd-turn-boundary-stop.sh）は
# #96 の 1 次対応で入った。欠けていたのは「次ターン冒頭で照合する」側である。
# Stop hook はターンを終わらせない方向にしか働かないので、**セッションを跨いだ
# 持ち越し**（前のセッションで owner を宣言して終えた作業）は誰も読み返さない。
# ここがその読み返しにあたる。
#
# --- 設計方針: 絶対に人の作業を止めない -------------------------------------
# SessionStart は監督の実セッション冒頭で必ず走る。ここで失敗すると、今日直した
# 無言スキップよりはるかに目立つ形で作業を止める。したがって:
#
#   * 全経路で exit 0。trap で異常時も 0 を返す。
#   * 出力は stdout の数行だけ（SessionStart の stdout は文脈へ入る）。
#   * 台帳が無い・壊れている・python が無い → 何も言わずに通す。
#     「持ち越しが無い」と「読めなかった」は区別して扱い、後者では
#     *何も主張しない*（誤った安心を与えない）。
#   * 出力は件数と id と detail だけ。プロンプト本文は読まないし出さない。
#
# --- 何を出すか ---------------------------------------------------------------
# 未解決の持ち越しがあるときだけ、照合すべき対象と確認コマンドを出す。
# 0 件なら沈黙する（毎セッション冒頭に定型文を出すと読まれなくなる — C14 の
# 保守税と同じ理由）。
#
# --- 他セッションの持ち越しには印を付ける ---------------------------------------
# 台帳は全セッションで共有である。他セッションが登録した持ち越しをここで「照合せよ」とだけ
# 出すと、無関係なセッションが他人の台帳を resolve / owner 宣言してしまう（前例あり:
# 「私のループが誤って上書きしたため訂正」）。入力の session_id と登録元が違う持ち越しには印を付ける:
#   登録から時間がたっていない → 登録したセッションが照合する想定なので、ここからは触らない
#   たった（stale）            → 登録したセッションは終わっている可能性がある。確かめて resolve / owner
#                                 宣言してよい（未宣言なら Stop hook が全セッションで止める）
# 触るなとだけ書くと、登録したセッションが終わった持ち越しをだれも照合しなくなる（#96 の無人区間）。
#
# --- 廃止条件 -----------------------------------------------------------------
# 出力された持ち越しが 30 日間一度も resolve されない → 台帳が「書くだけ」に
# 劣化した証拠として棚卸し issue。発火ゼロ 90 日 → 降格候補（H6 共通様式）。
set -uo pipefail
trap 'exit 0' EXIT

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
[ -f "$_LEDGER_LIB" ] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

ASYNC_SH=""
for _cand in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/async-work.sh" \
  "$HOME/.claude/scripts/async-work.sh" \
  "$HOME/Developer/claude-code-skills/scripts/async-work.sh"
do
  [ -f "$_cand" ] && ASYNC_SH="$_cand" && break
done

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0
# 入力の session_id。空でない文字列で、前後に空白が無いものだけを使う（それ以外は印を付けない）
session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("session_id")
except Exception:
    v = None
print(v if isinstance(v, str) and v and v == v.strip() else "")
' 2>/dev/null || true)"
if [ -z "$ASYNC_SH" ]; then
  # 台帳 CLI が無い = 照合できない。「持ち越し 0」と誤解させないため沈黙するが、
  # 効いていないことは stderr へ残す（無言で無効化しない — #348 の教訓）。
  printf '[carryover] scripts/async-work.sh が見つからないため持ち越し照合を省略しました。\n' >&2
  exit 0
fi

# 台帳 CLI が --session を知らない版ずれでは、印を付けずに従来どおり全件を出す（沈黙しない）。
if ! unresolved="$(bash "$ASYNC_SH" unresolved --session "$session" 2>/dev/null)"; then
  session=""
  unresolved="$(bash "$ASYNC_SH" unresolved 2>/dev/null || true)"
fi
[ -n "$unresolved" ] || exit 0

# 照合の文面を作るプログラム。台帳の JSON は stdin で渡す（引数で渡すと大きな台帳を渡せない）。
IFS= read -r -d '' REPORT_PY <<'PY'
import json, sys

try:
    rows = json.loads(sys.stdin.read() or "[]")
except Exception:
    rows = []
if not isinstance(rows, list):
    rows = []
rows = [r for r in rows if isinstance(r, dict)]
if not rows:
    raise SystemExit(0)
session = sys.argv[1] if len(sys.argv) > 1 else ""
# 台帳 CLI が mine / stale を付けない（古い版）なら、誰の持ち越しか区別できないので印を付けない
if session and any("mine" not in r or "stale" not in r for r in rows):
    session = ""


def age(r):
    s = r.get("age_s")
    return "%.1f 時間" % (s / 3600.0) if isinstance(s, (int, float)) and not isinstance(s, bool) else "不明"


# 出すのは id / kind / detail / owner のみ。プロンプト本文は元から持たない。
lines = ["## 前ターンからの持ち越し（未解決の非同期作業 %d 件）" % len(rows), ""]
for r in rows[:20]:
    owner = str(r.get("owner") or "").strip()
    lines.append("- [%s] `%s` — %s" % (r.get("kind", ""), r.get("id", ""),
                                       r.get("detail", "")))
    lines.append("  - 確認する主体: %s" % (owner if owner else "**未宣言**"))
    if session and not r.get("mine"):
        where = "別セッション（session=%s、登録から %s）" % (r.get("session") or "不明", age(r))
        if r.get("stale"):
            lines.append("  - 登録元: %s。登録から時間がたっており、登録したセッションは終わっている可能性が"
                         "ある。conclusion を読んで resolve するか、owner を宣言してよい" % where)
        else:
            lines.append("  - 登録元: %s。登録したセッションが照合する想定なので、このセッションからは"
                         " resolve / owner 宣言しない（そのセッションが終わっていると分かっているなら"
                         "、conclusion を読んで resolve してよい）" % where)
    if r.get("check_cmd"):
        lines.append("  - 確認: `%s`" % r["check_cmd"])
if len(rows) > 20:
    lines.append("- ...他 %d 件" % (len(rows) - 20))
lines += [
    "",
    "このターンの冒頭で照合すること。`status=in_progress` は前進の証拠ではない。",
    "終端するには conclusion を読み出す:",
    "```",
    "gh run view <id> --json status,conclusion",
    "scripts/async-work.sh resolve --id <id> --conclusion <success|failure>",
    "```",
]
print("\n".join(lines))
PY

report="$(printf '%s' "$unresolved" | python3 -c "$REPORT_PY" "$session" 2>/dev/null || true)"
[ -n "$report" ] || exit 0

printf '%s\n' "$report"

if declare -F aidd_ledger_append_record >/dev/null 2>&1; then
  row="$(printf '%s' "$unresolved" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
unowned = len([r for r in rows if not r.get("owned")])
print(json.dumps({"component": "H1", "event": "measure",
                  "rule": "carryover-reconciled",
                  "detail": "session start: %d carried over (%d unowned)" % (len(rows), unowned),
                  "subject": {"carried_over": len(rows), "unowned": unowned}},
                 ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"
  [ -n "$row" ] && aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true
fi

exit 0
