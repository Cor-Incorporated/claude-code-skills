#!/usr/bin/env bash
# Stop hook: 未完了の非同期作業を残したままターンを終えさせない.
#
# Issue: Cor-Incorporated/aidd-governance#96（監督が in_progress を「進んでいる」と
#        報告して停止し、11 分後の失敗を 7 時間 25 分だれも検知しなかった）
#        Cor-Incorporated/aidd-governance#95（レーンが正常終了で減るのに補充されない）
#
# --- なぜ Stop hook なのか ------------------------------------------------------
#   エージェントは連続稼働しない。ターンとターンの間は完全に停止する。
#   したがって「誰が完了を確認するか」を宣言しないままターンを終えると、
#   非同期作業の結果を受け取る主体が存在しなくなる。
#   Stop はエージェントが停止しようとする瞬間に走る唯一の関門であり、
#   ここは *まだ* エージェントが生きている。exit 2 で停止を拒否できる。
#
# --- この装置が閉じない穴（正直に書く。ここを誤魔化してはならない） -------------
#   本装置が止められるのは「持ち越しがあるのにターンを終えようとした」瞬間だけ
#   である。持ち越しを解決するか owner を宣言してターンが *正当に* 終わった後、
#   その先の無人区間はだれも見ていない。#96 の 7 時間 25 分そのものを短くするには
#   ターンの外で生きるプロセス（常駐 daemon / スケジュール実行）が要る。
#   本 PR にそれは含まれない。Stop hook では原理的に代替できない。
#
#   したがって本装置の効果は「無人区間の発生を、宣言なしには始められなくする」
#   ことであって「無人区間を検知すること」ではない。
#
# --- 止めるのは自分のセッションの持ち越しと、登録元が照合していない持ち越し -----
#   台帳（~/.claude/state/async-work）は全セッションで共有である。2026-09-28、別セッションが
#   自動登録した corsweb2024 の run 2 件と ai-cluster の nohup が、無関係な claude-code-skills の
#   セッションのターン終了を止め、そのセッションは他人の持ち越しを resolve / owner 宣言する
#   しかなかった（他人の台帳を書き換える）。停止判定は入力の session_id と一致する持ち越しで行う。
#   他セッション・session 不明の未宣言の持ち越しは、登録から時間がたっていなければ情報として出す
#   （止めない）。たっていれば全セッションで止める（stale。閾値は台帳 CLI が持つ）。session_id からは
#   「生きている別セッション」と「終わったセッション」を区別できず、終わっていれば、ほかに照合する
#   主体がいないからである（#96 の無人区間を他セッションへ押しつけない）。
#   入力に session_id が無い・文字列でないとき、台帳 CLI が分類を返さない（古い版）ときは、誰の持ち越しか
#   区別できないので従来どおり全件で止める（黙ってガードを無効にしない）。
#
# --- 無限ループ防止 -------------------------------------------------------------
#   stop_hook_active=true は「前回の Stop hook が停止を拒否したため継続している」
#   状態を指す。ここで再び拒否すると停止できなくなる。必ず素通しする。
#
# --- 廃止条件 -------------------------------------------------------------------
#   誤ブロック率（持ち越しが実際は完了していたのに止めた）> 30%/四半期 →
#   自動登録の検出条件を狭める。発火ゼロ 90 日 → 降格候補。
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
[ -f "$_LEDGER_LIB" ] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# 台帳 CLI の解決順。setup.sh は hooks/*.sh を ~/.claude/hooks/ へ、scripts/* を
# ~/.claude/scripts/ へ配る。したがって配備後のレイアウトでは 2 番目が正である。
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
# 台帳が見つからないときに黙って exit 0 すると、ガードが「配備されているのに
# 効いていない」状態になる。停止は許すが（壊れた関門で作業を止めない）、
# 効いていないことは必ず言う。
if [ -z "$ASYNC_SH" ]; then
  printf '[turn-boundary] WARNING: scripts/async-work.sh が見つからない。持ち越し検査は無効。\n' >&2
  exit 0
fi

# 継続中（前回この hook が止めた）なら必ず素通しする。
active="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("false"); raise SystemExit(0)
print("true" if isinstance(d, dict) and d.get("stop_hook_active") else "false")
' 2>/dev/null || echo false)"
if [ "$active" = "true" ]; then
  exit 0
fi

# 入力の session_id。空でない文字列で、前後に空白が無いものだけを使う。それ以外は区別できないものとして
# 扱う（全件で止める側に倒す）
session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("session_id")
except Exception:
    v = None
print(v if isinstance(v, str) and v and v == v.strip() else "")
' 2>/dev/null || true)"

# 台帳 CLI が --session を知らない（hooks だけ新しく配備された版ずれ）と非 0 で終わる。そのときは
# 誰の持ち越しか区別できないので session を捨て、従来どおり全件で判定する（空配列で素通しにしない）。
if ! unresolved="$(bash "$ASYNC_SH" unresolved --session "$session" 2>/dev/null)"; then
  session=""
  unresolved="$(bash "$ASYNC_SH" unresolved 2>/dev/null || echo '[]')"
fi

# 判定のプログラム。台帳の JSON は stdin で渡す（引数で渡すと、Linux では 1 引数 128 KiB を超えた台帳を
# 渡せず判定ごと素通しになる）。プログラムは -c で渡す（`python3 - <<'PY'` はプログラム自体を stdin から
# 読むので、データと同じ stdin は使えない）。
IFS= read -r -d '' VERDICT_PY <<'PY'
import json, sys

try:
    rows = json.loads(sys.stdin.read() or "[]")
except Exception:
    rows = []
if not isinstance(rows, list):
    rows = []
rows = [r for r in rows if isinstance(r, dict)]
session = sys.argv[2] if len(sys.argv) > 2 else ""
# 台帳 CLI が mine / stale を付けない（--session を黙って無視する古い版）なら、誰の持ち越しか区別できない。
# 全件を自分の分として扱う（従来どおり止める）
if session and any("mine" not in r or "stale" not in r for r in rows):
    session = ""


def mine(r):
    return bool(r.get("mine")) if session else True


def age(r):
    s = r.get("age_s")
    return "%.1f 時間" % (s / 3600.0) if isinstance(s, (int, float)) and not isinstance(s, bool) else "不明"


# owner が宣言されている持ち越しは「次に誰がいつ確認するか」が書かれている。
# #96 の要求は「確認する主体を宣言せずに終えない」ことであって、非同期作業を
# 禁じることではない。宣言済みは warn に落とす。
unowned = [r for r in rows if not r.get("owned") and mine(r)]
owned = [r for r in rows if r.get("owned") and mine(r)]
foreign = [r for r in rows if not r.get("owned") and not mine(r)]
# 他セッション・登録元不明の未宣言の持ち越しのうち、登録から時間がたったもの。登録したセッションが終わって
# いれば、ほかに照合する主体がいないので止める
orphaned = [r for r in foreign if r.get("stale")]
others = [r for r in foreign if not r.get("stale")]

# #95: 目標並列度が宣言されているとき、稼働レーン数が下回ったままターンを
# 終えるのは「枠が空いたのに埋めなかった」ことである。稼働レーンはセッションを問わず数える
# （/clear や再起動で session が変わっても、走っているレーンは減っていない）。
target = 0
try:
    target = int(sys.argv[1])
except (IndexError, ValueError):
    target = 0
lanes = [r for r in rows if r.get("kind") == "lane"]
deficit = max(0, target - len(lanes)) if target > 0 else 0

lines = []
if unowned:
    lines.append(
        "未完了の非同期作業が %d 件あり、確認する主体が宣言されていない:" % len(unowned)
    )
    for row in unowned[:10]:
        lines.append(
            "  - [%s] %s : %s" % (row.get("kind", ""), row.get("id", ""), row.get("detail", ""))
        )
        if row.get("check_cmd"):
            lines.append("      確認: %s" % row["check_cmd"])
if orphaned:
    if lines:
        lines.append("")
    lines.append(
        "他セッション・登録元不明の未宣言の持ち越しが %d 件あり、登録から時間がたっている。"
        "登録したセッションは終わっている可能性があり、ほかに照合する主体がいない:" % len(orphaned)
    )
    for row in orphaned[:10]:
        lines.append(
            "  - [%s] %s : %s（session=%s、登録から %s）" % (
                row.get("kind", ""), row.get("id", ""), row.get("detail", ""),
                row.get("session") or "不明", age(row))
        )
        if row.get("check_cmd"):
            lines.append("      確認: %s" % row["check_cmd"])
if unowned or orphaned:
    lines.append("")
    lines.append("次のいずれかを行ってからターンを終えること:")
    lines.append("  (a) 完了を確認して終端する（conclusion の読み出しが要る。")
    lines.append("      status=in_progress は前進の証拠ではない）:")
    lines.append("        gh run view <id> --json status,conclusion")
    lines.append("        scripts/async-work.sh resolve --id <id> --conclusion <success|failure>")
    lines.append("  (b) 次に誰がいつ確認するかを宣言する:")
    lines.append("        scripts/async-work.sh register --id <id> --kind <kind> \\")
    lines.append("            --owner '<誰が・いつ>' --check-cmd '<確認コマンド>'")
if others:
    if lines:
        lines.append("")
    lines.append(
        "（情報）他セッション・登録元不明の未宣言の持ち越し %d 件。登録から時間がたっていないので、"
        "このセッションの停止は止めない。登録したセッションが照合する想定なので、ここから resolve / "
        "owner 宣言しないこと（そのセッションが /clear・再起動などで終わっていると分かっているなら、"
        "conclusion を読んで resolve してよい）:" % len(others)
    )
    for row in others[:10]:
        lines.append(
            "  - [%s] %s : %s（session=%s、登録から %s）" % (
                row.get("kind", ""), row.get("id", ""), row.get("detail", ""),
                row.get("session") or "不明", age(row))
        )
if deficit > 0:
    lines.append("")
    lines.append(
        "稼働レーンが目標並列度を %d 下回っている (target=%d, running=%d)。"
        % (deficit, target, len(lanes))
    )
    lines.append(
        "  完了イベントは 2 つの事実を含む: 「成果が出た(回収せよ)」と「枠が空いた(埋めよ)」。"
    )
    lines.append("  後者を落としたままターンを終えないこと。")

print(json.dumps({
    "block": bool(unowned) or bool(orphaned) or deficit > 0,
    "unowned": len(unowned),
    "owned": len(owned),
    "orphaned": len(orphaned),
    "others": len(others),
    "lanes": len(lanes),
    "target": target,
    "deficit": deficit,
    "reason": "\n".join(lines),
}, ensure_ascii=False))
PY

verdict="$(printf '%s' "$unresolved" | python3 -c "$VERDICT_PY" "${AIDD_LANE_TARGET:-0}" "$session" 2>/dev/null || true)"
[ -n "$verdict" ] || exit 0

field() { # field <名前> → verdict の値（読めなければ 0）
  printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" 2>/dev/null || echo 0
}

should_block="$(printf '%s' "$verdict" | python3 -c '
import json, sys
try:
    print("yes" if json.load(sys.stdin).get("block") else "no")
except Exception:
    print("no")
' 2>/dev/null || echo no)"

ledger_row() {
  printf '%s' "$verdict" | python3 -c '
import json, sys
v = json.load(sys.stdin)
print(json.dumps({
    "component": "H1", "event": sys.argv[1], "rule": sys.argv[2],
    "detail": "unowned=%d owned=%d orphaned=%d others=%d lanes=%d/%d" % (
        v["unowned"], v["owned"], v["orphaned"], v["others"], v["lanes"], v["target"]),
    "subject": {"unowned": v["unowned"], "owned": v["owned"], "orphaned": v["orphaned"],
                "others": v["others"], "lanes": v["lanes"], "lane_target": v["target"],
                "deficit": v["deficit"]},
}, ensure_ascii=False, separators=(",", ":")))
' "$1" "$2" 2>/dev/null || true
}

append_ledger() {
  declare -F aidd_ledger_append_record >/dev/null 2>&1 || return 0
  local row
  row="$(ledger_row "$1" "$2")"
  [ -n "$row" ] && aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true
}

# 他セッションの（時間のたっていない）未宣言の持ち越しは止めないが、止める・止めないに関わらず記録する。
others_n="$(field others)"
[ "${others_n:-0}" -gt 0 ] && append_ledger warn async-work-other-session

if [ "$should_block" != "yes" ]; then
  # 宣言済みの持ち越しがあるなら、素通しはするが記録は残す。
  owned_n="$(field owned)"
  [ "${owned_n:-0}" -gt 0 ] && append_ledger warn async-work-owned
  # 他セッションの持ち越しは、見えるように出す（exit 0 の stderr はエージェントには届かない。
  # エージェントには SessionStart の照合で届く）。
  if [ "${others_n:-0}" -gt 0 ]; then
    printf '%s\n' "$(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')" >&2
  fi
  exit 0
fi

append_ledger block turn-boundary-unresolved
printf '%s\n' "$(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')" >&2
# Stop hook の exit 2 = 停止を拒否し、stderr をエージェントへ返す。
exit 2
