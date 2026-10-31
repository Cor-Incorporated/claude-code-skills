#!/usr/bin/env bash
# PostToolUse(Bash): ターンをまたぐ非同期作業を自動で持ち越し台帳へ登録する.
#
# Issue: Cor-Incorporated/aidd-governance#96
#
# なぜ自動登録が要るか:
#   持ち越し台帳を「監督が思い出したら書く」運用にすると、#96 の失敗そのものが
#   再現する。監督は非同期作業を起動したことを *報告* はしたが、それを
#   *持ち越し* として扱わなかった。忘れた時に効かない装置は、忘れることが
#   失敗形である問題には効かない。
#
# 検出は意図的に狭くしてある（誤検知はターン終了を無意味に止めるため）:
#   gh workflow run   — ワークフローを発射した。結果はターンの外で出る
#   gh run watch      — 完走待ちを始めた。待ちはツール呼び出しより長く続きうる
#   nohup             — 明示的にツール呼び出しより長生きさせた
#
#   これ以外の方法で起動した背景ジョブは **検出できない**。`somescript.sh &` の
#   ような素の背景化は対象外であり、手動で scripts/async-work.sh register を
#   呼ぶ必要がある。この限界を隠して「全ての非同期作業を捕捉する」と書いては
#   ならない。
#
# 失敗しても作業は止めない（PostToolUse は観測点であって関門ではない）。
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
[ -f "$_LEDGER_LIB" ] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# 解決順は hooks/aidd-turn-boundary-stop.sh と同じ。setup.sh は scripts/* を
# ~/.claude/scripts/ へ配るので、配備後は 2 番目が正である。
ASYNC_SH=""
for _cand in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/async-work.sh" \
  "$HOME/.claude/scripts/async-work.sh" \
  "$HOME/Developer/claude-code-skills/scripts/async-work.sh"
do
  [ -f "$_cand" ] && ASYNC_SH="$_cand" && break
done
if [ -z "$ASYNC_SH" ]; then
  printf '[async-work] WARNING: scripts/async-work.sh が見つからない。自動登録は無効。\n' >&2
  exit 0
fi

# ハーネス共通のテスト規約。テスト実行が共有状態を汚し、他セッションのターンを
# 止めるのを防ぐ。**登録はする**（「テスト実行があった」ことを追えるようにする）が、
# source を test 系にして停止判定の入力から外す。黙って捨てると、テストが台帳へ
# 書けているのかどうかが分からなくなる。
# 由来: 2026-09-02、cluster-c と本レーンのテスト検体が監督の共有台帳へ入り、
# 監督のターンが Stop hook で止まった。
REGISTER_SOURCE="posttooluse-auto"
case "${AIDD_LEDGER_SOURCE:-}" in
  test | test:*) REGISTER_SOURCE="test:posttooluse-auto" ;;
esac

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0
# 入力の全体を一時ファイルに置く。classify は実行結果（tool_response の rc と出力）も読む。
# 出力は大きくなりうるので、環境変数や引数では渡さない。
input_file="$(mktemp "${TMPDIR:-/tmp}/aidd-async-register.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$input_file"' EXIT
printf '%s' "$input" >"$input_file"

# コマンド文字列と、あれば実行結果テキストを取り出す。
cmd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
ti = d.get("tool_input") or {}
print(ti.get("command") or ti.get("cmd") or d.get("command") or "")
' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# 登録したセッション。台帳は全セッションで共有なので、Stop hook が自分の持ち越しだけで止められる
# よう、hook の入力の session_id を記録する（空でない文字列で前後に空白が無いものだけ。無ければ
# CLAUDE_CODE_SESSION_ID）。
session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("session_id")
except Exception:
    v = None
print(v if isinstance(v, str) and v and v == v.strip() else "")
' 2>/dev/null || true)"
[ -n "$session" ] || session="${CLAUDE_CODE_SESSION_ID:-}"

# 分類。1 行 1 件 "<kind>\t<id>\t<detail>" を出す。
# コマンド文字列は argv で渡す。`python3 - <<'PY'` はプログラム自体を stdin から
# 読むので、同じ stdin へパイプすると sys.stdin.read() が空になる。
# heredoc は関数に入れる。$( ) の中に置くと、macOS の /bin/bash 3.2 は本文の Python のコメントにある
# 対でない括弧まで構文として読み、hook ごと構文エラーになる（自動登録が黙って止まる）。
classify() {
  python3 - "$1" "$2" <<'PY'
import hashlib, json, re, shlex, sys, time

cmd = sys.argv[1]
out = []

# 実行結果。終了コードの読み方は hooks/lib/aidd_cc.py の _exit_status（ADR-011）と同じにする:
#   - tool_response に exit_code があればそれ。
#   - Claude Code の PostToolUse は成功の event。前景で終わった呼び出しは rc 0。
#   - 背景に送った・時間切れ・中断（backgroundTaskId / timedOutAfterMs / interrupted）は不明。
#   - returnCodeInterpretation があるものは rc 1。
#   - tool_response が無い入力（古い版・テスト）も不明。
# 不明なときは、従来どおりコマンドの形だけで決める（見落とし 1 件より、毎ターン止まるほうの害が大きい）。
rc, said = None, ""
try:
    payload = json.load(open(sys.argv[2], encoding="utf-8"))
except (OSError, ValueError):
    payload = {}
resp = payload.get("tool_response") if isinstance(payload, dict) else None
if isinstance(resp, dict):
    said = "\n".join(str(resp.get(k) or "") for k in ("stdout", "stderr", "output"))
    code = resp.get("exit_code", resp.get("exitCode", resp.get("rc")))
    if isinstance(code, int) and not isinstance(code, bool):
        rc = code
    elif resp.get("backgroundTaskId") or resp.get("background_task_id") or resp.get("timedOutAfterMs") \
            or resp.get("interrupted") is True:
        rc = None
    elif resp.get("returnCodeInterpretation"):
        rc = 1
    elif payload.get("hook_event_name") == "PostToolUse":
        rc = 0
elif isinstance(resp, str):
    said = resp


def ident(prefix, seed):
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:10]
    return "%s-%s-%s" % (prefix, time.strftime("%Y%m%dT%H%M%S"), digest)


# gh workflow run <wf> — 発射した。conclusion はターンの外で決まる。
# --- 実行と引用の区別 (aidd-governance#100) ---------------------------------
# 2026-09-02 実測: 文字列として `gh workflow run v2-alpha-cd.yml` を含むだけの
# コマンドが持ち越しとして登録され、Stop hook がターンを止めた。実際には Grift の
# Alpha CD は発射されておらず（直近 run は 5 時間前の別物）、登録は誤検知だった。
#
# 誤検知した 3 形（すべて再現済み）:
#   grep -rn 'gh workflow run v2-alpha-cd.yml' design/
#   cat <<'EOF' > doc.md ... gh workflow run v2-alpha-cd.yml ... EOF
#   echo "手順: gh workflow run v2-alpha-cd.yml"
#
# #100 が言う「承認の有無でなくパターンでゲートを引く誤分類」そのものである。
# 対策は 2 つ。(1) heredoc の本文を照合対象から外す。(2) コマンド位置
# （文頭 / 改行後 / ; && || | ( { の直後）に現れたものだけを実行とみなす。
#
# **意図的な取りこぼし**: `bash -c "gh workflow run x"` のように引用符の内側から
# 起動する形は登録されない。これは本 hook が block ではなく登録（可視化）であり、
# 見落とし 1 件より「毎ターン止まる」ほうが害が大きいという判断による。
# 取りこぼしが問題になったら手動登録できる: async-work.sh register --id ...
def strip_heredocs(text):
    """heredoc の本文を落とす。本文は実行されるコマンドではなくデータである。"""
    lines = text.split("\n")
    kept, terminator = [], None
    for line in lines:
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            continue
        kept.append(line)
        hd = re.search(r"<<-?\s*[\"\']?([A-Za-z_][A-Za-z0-9_]*)[\"\']?", line)
        if hd:
            terminator = hd.group(1)
    return "\n".join(kept)


# コマンド位置は、引用を外した語で決める (#459, 2026-10-31)。それまでの正規表現
# `(?:\A|[\n;&|(){}]\s*)` は引用を区別せず、`echo "--- commands (gh workflow run lines)"` の
# 引用の中の `(` の直後をコマンド位置とみなし、`lines)"` を workflow 名とする cd-run を登録した。
# shlex（punctuation_chars）で語に分け、区切り（; && || | & ( ) { } と改行）の直後の語だけを見る。
# 引用が閉じていないコマンドは shell も実行しないので、何も登録しない。
SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", ";;", "|&"}


def simple_commands(text):
    """引用を外した語のリストを、単純コマンドごとに返す（先頭の VAR=value は除く）。"""
    lexer = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        words = list(lexer)
    except ValueError:
        return []
    cmds, cur = [], []
    for w in words:
        if w in SEPARATORS or set(w) <= set(";&|()"):
            if cur:
                cmds.append(cur)
            cur = []
            continue
        if not cur and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", w):
            continue
        cur.append(w)
    if cur:
        cmds.append(cur)
    return cmds


scan = strip_heredocs(cmd)
RUN_URL = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/actions/runs/(\d+)")

for words in simple_commands(scan):
    # gh workflow run <wf> — 発射した。登録の根拠は実行結果にする (#459): 終了コードが分かれば 0 のときだけ、
    # 出力があれば「Created workflow_dispatch event」か run の URL があるときだけ。run の URL があれば
    # id は run-<run id> にして、後の `gh run watch <run id>` と同じ持ち越しにする。
    if words[:3] == ["gh", "workflow", "run"] and len(words) > 3:
        wf = words[3]
        if rc is not None and rc != 0:
            continue
        if rc is not None and not (RUN_URL.search(said) or "Created workflow_dispatch event" in said):
            continue
        m = RUN_URL.search(said)
        rid = m.group(1) if m else ""
        out.append(("cd-run", "run-%s" % rid if rid else ident("wf", wf + cmd),
                    "gh workflow run %s%s" % (wf, " (run %s)" % rid if rid else "")))
    # gh run watch <id> — 完走待ち。待ちはツール呼び出しの寿命を超えうる。
    elif words[:3] == ["gh", "run", "watch"] and len(words) > 3 and words[3].isdigit():
        out.append(("cd-run", "run-%s" % words[3], "gh run watch %s" % words[3]))
    # nohup — 明示的にツール呼び出しより長生きさせた。
    elif words[0] == "nohup" and len(words) > 1:
        head = re.sub(r"\s+", " ", cmd).strip()[:120]
        out.append(("generic", ident("nohup", cmd), "nohup: %s" % head))

for kind, ident_, detail in out:
    print("%s\t%s\t%s" % (kind, ident_, detail))
PY
}
matches="$(classify "$cmd" "$input_file" 2>/dev/null || true)"
[ -n "$matches" ] || exit 0

while IFS=$'\t' read -r kind ident detail; do
  [ -n "$ident" ] || continue
  stored_session="$session"
  if ! bash "$ASYNC_SH" register --id "$ident" --kind "$kind" --detail "$detail" \
    --source "$REGISTER_SOURCE" --session "$session" >/dev/null 2>&1; then
    # 台帳 CLI が --session を知らない版ずれでも登録は落とさない（登録元の記録だけを諦める）。
    bash "$ASYNC_SH" register --id "$ident" --kind "$kind" --detail "$detail" \
      --source "$REGISTER_SOURCE" >/dev/null 2>&1 || continue
    stored_session=""
  fi
  printf '[async-work] 持ち越し登録: %s (%s)\n' "$ident" "$detail" >&2
  if declare -F aidd_ledger_append_record >/dev/null 2>&1; then
    python3 - "$kind" "$ident" "$detail" "$stored_session" <<'PY' | while IFS= read -r row; do
import json, sys
kind, ident, detail, session = sys.argv[1:5]
print(json.dumps({"component": "H1", "event": "measure", "rule": "async-work-registered",
                  "detail": detail,
                  "subject": {"id": ident, "kind": kind, "source": "posttooluse-auto",
                              "session": session}},
                 ensure_ascii=False, separators=(",", ":")))
PY
      aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true
    done
  fi
done <<<"$matches"

exit 0
