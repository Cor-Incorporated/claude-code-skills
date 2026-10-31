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
#   判定の仕方 (#459 / #471、2026-10-31):
#   - 語は引用を外して読む。
#   - コマンド位置は区切り（; & | ( ) と改行）の直後だけ。
#   - $( ) とバッククォートの本文もコマンドとして見る。
#   - 先頭の VAR=x / env / command / timeout / nice は読み飛ばす。
#   - gh workflow run を外すのは、その行の唯一のコマンドが rc≠0 で終わったときと --help のときだけ。
#     tty の無い gh は run の URL しか出さないか、何も出さない。だから出力が無いことは、
#     発射していない証拠にならない。
#   検出できない形も残っている:
#   - bash -c "…" の引用の中
#   - eval
#   - 変数に入れたコマンド（$CMD）
#   - 関数や alias の中
#   - ファイルにしたスクリプト
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
import hashlib, json, re, sys, time

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
# 小さな字句解析で単純コマンドの語に分ける。
#   - 区切りは ; & | ( ) と改行。
#   - '…'、"…"、$'…'、\ の後の改行、${…} を扱う。
#   - # は語の先頭だけでコメントになる（a#b、$# は語）。
#   - $( ) とバッククォートの本文は、single quote の外にあれば、それ自体をコマンドとして判定する
#     （URL="$(gh workflow run x)" は発射である）。
#   - 先頭の VAR=value、env / command / timeout <時間> / nice は前置きとして読み飛ばす。
# 解析できない文字列（引用が閉じていないなど）は、旧来の正規表現で判定する。
AT_COMMAND = r"(?:\A|[\n;&|(){}]\s*)"
SEP = set(";&|(){}")


def match_close(text, i, open_ch="(", close_ch=")"):
    """text[i] == open_ch. Index of the matching close_ch, skipping quoted parts; ValueError when unbalanced."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = text.find("'", j + 1)
            if k < 0:
                raise ValueError("unclosed '")
            j = k + 1
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise ValueError("unbalanced " + open_ch)


def lex(text):
    """(simple commands as lists of unquoted words, bodies of $( ) / backticks outside single quotes)."""
    cmds, cur, subs = [], [], []
    word = None
    i, n = 0, len(text)

    def add(s):
        nonlocal word
        word = (word or "") + s

    def end_word():
        nonlocal word
        if word is not None:
            cur.append(word)
            word = None

    def end_cmd():
        nonlocal cur
        end_word()
        if cur:
            cmds.append(cur)
        cur = []

    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            if text[i + 1] != "\n":
                add(text[i + 1])
            i += 2
        elif text.startswith("$'", i):
            j, buf = i + 2, ""
            while j < n and text[j] != "'":
                if text[j] == "\\" and j + 1 < n:
                    buf += text[j + 1]
                    j += 2
                    continue
                buf += text[j]
                j += 1
            if j >= n:
                raise ValueError("unclosed $'")
            add(buf)
            i = j + 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ValueError("unclosed '")
            add(text[i + 1:j])
            i = j + 1
        elif c == '"':
            j, buf = i + 1, ""
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf += text[j + 1]
                    j += 2
                elif text.startswith("$(", j) and not text.startswith("$((", j):
                    k = match_close(text, j + 1)
                    subs.append(text[j + 2:k])
                    buf += text[j:k + 1]
                    j = k + 1
                elif text[j] == "`":
                    k = text.find("`", j + 1)
                    if k < 0:
                        raise ValueError("unclosed `")
                    subs.append(text[j + 1:k])
                    buf += text[j:k + 1]
                    j = k + 1
                else:
                    buf += text[j]
                    j += 1
            if j >= n:
                raise ValueError('unclosed "')
            add(buf)
            i = j + 1
        elif text.startswith("$((", i):
            k = match_close(text, i + 1)
            add(text[i:k + 1])
            i = k + 1
        elif text.startswith("$(", i):
            k = match_close(text, i + 1)
            subs.append(text[i + 2:k])
            add(text[i:k + 1])
            i = k + 1
        elif text.startswith("${", i):
            k = match_close(text, i + 1, "{", "}")
            add(text[i:k + 1])
            i = k + 1
        elif c == "`":
            k = text.find("`", i + 1)
            if k < 0:
                raise ValueError("unclosed `")
            subs.append(text[i + 1:k])
            add(text[i:k + 1])
            i = k + 1
        elif c == "#" and word is None:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in " \t\r":
            end_word()
            i += 1
        elif c == "\n" or c in SEP:
            # `2>&1` / `&>`: an & right after > or before > is a redirection, not a separator
            if c == "&" and ((word or "").endswith(">") or text.startswith("&>", i)):
                add(c)
                i += 1
                continue
            end_cmd()
            i += 1
        else:
            add(c)
            i += 1
    if word is not None or cur:
        end_cmd()
    return cmds, subs


def strip_prefix(words):
    """Drop leading VAR=value words and the env / command / timeout <dur> / nice wrappers."""
    w = list(words)
    while w:
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*=", w[0]):
            w = w[1:]
        elif w[0] in ("env", "command", "nice", "builtin", "time", "!", "xargs", "sudo"):
            # options that take a value: env -u NAME / -C DIR, nice -n N, xargs -I R / -n N / -P N
            takes = {"env": {"-u", "-C", "-S"}, "nice": {"-n"}, "xargs": {"-I", "-n", "-P", "-L", "-s", "-E", "-d"},
                     "sudo": {"-u", "-g", "-C", "-D"}}.get(w[0], set())
            w = w[1:]
            while w and (w[0].startswith("-") or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", w[0])):
                w = w[2:] if w[0] in takes else w[1:]
        elif w[0] in ("timeout", "gtimeout"):
            w = w[1:]
            while w and w[0].startswith("-"):
                w = w[2:] if w[0] in ("-s", "-k", "--signal", "--kill-after") else w[1:]
            w = w[1:]  # the duration
        else:
            break
    return w


def simple_commands(text, depth=0):
    """Every simple command, $( ) and backtick bodies included. None when the text cannot be lexed."""
    try:
        cmds, subs = lex(text)
    except ValueError:
        return None
    out_cmds = [strip_prefix(c) for c in cmds]
    if depth < 4:
        for s in subs:
            inner = simple_commands(s, depth + 1)
            out_cmds.extend(inner or [])
    return [c for c in out_cmds if c]


def legacy_commands(text):
    """The pre-#459 regex, for text the lexer cannot read (commands at its command positions)."""
    found = []
    for m in re.finditer(AT_COMMAND + r"gh\s+workflow\s+run\s+([^\s;|&]+)", text):
        found.append(["gh", "workflow", "run", m.group(1)])
    for m in re.finditer(AT_COMMAND + r"gh\s+run\s+watch\s+(\d+)", text):
        found.append(["gh", "run", "watch", m.group(1)])
    if re.search(AT_COMMAND + r"nohup\s", text):
        found.append(["nohup", "?"])
    return found


scan = strip_heredocs(cmd)
commands = simple_commands(scan)
if commands is None:
    # The lexer could not read it. If bash cannot either (an unclosed quote), nothing ran; otherwise use the
    # pre-#459 regex rather than miss a launch the lexer does not understand.
    import subprocess
    try:
        parses = subprocess.run(["bash", "-n", "-c", scan], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        parses = True
    commands = legacy_commands(scan) if parses else []
# Any host: GitHub Enterprise prints its own (claude-code-skills#471 review).
RUN_URL = re.compile(r"https?://[^/\s]+/[^/\s]+/[^/\s]+/actions/runs/(\d+)")

launches = []
for words in commands:
    # gh workflow run <wf> — 発射した。外すのは、実行が失敗したと分かるとき（rc が 0 以外）と --help だけ。
    # Claude Code の Bash には tty が無く、gh は run の URL だけを出すか、何も出さない（204 の経路・GHES・古い gh）。
    # 出力が無いことは「発射していない」証拠にならない (#471 review)。
    if words[:3] == ["gh", "workflow", "run"] and len(words) > 3:
        # rc は行の最後のコマンドのもの。発射が行の唯一のコマンドのときだけ、失敗の証拠になる
        # （`gh workflow run x && gh run list | grep -q x` の grep が 1 で終わっても、発射はしている）。
        if (rc is not None and rc != 0 and len(commands) == 1) or "--help" in words or "-h" in words:
            continue
        launches.append(words[3])
    # gh run watch <id> — 完走待ち。待ちはツール呼び出しの寿命を超えうる。
    elif words[:3] == ["gh", "run", "watch"] and len(words) > 3 and words[3].isdigit():
        out.append(("cd-run", "run-%s" % words[3], "gh run watch %s" % words[3]))
    # nohup — 明示的にツール呼び出しより長生きさせた。
    elif words[0] == "nohup" and len(words) > 1:
        head = re.sub(r"\s+", " ", cmd).strip()[:120]
        out.append(("generic", ident("nohup", cmd), "nohup: %s" % head))
# run の URL は、発射と同じ数だけあるときに順に割り当てる（id は run-<run id>、後の gh run watch と同じ持ち越し）。
# 数が合わなければ（別の run の URL が混じる・出力が無い）、URL は使わない。
urls = RUN_URL.findall(said) if launches else []
for k, wf in enumerate(launches):
    # Only when every command on the line is a launch: `gh workflow run x && gh run list --limit 1 --json url`
    # prints the PREVIOUS run's URL when the launch prints nothing (#471 review round 2).
    rid = urls[k] if len(urls) == len(launches) == len(commands) else ""
    out.append(("cd-run", "run-%s" % rid if rid else ident("wf", "%s#%d#%s" % (wf, k, cmd)),
                "gh workflow run %s%s" % (wf, " (run %s)" % rid if rid else "")))

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
