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

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0

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

# 分類。1 行 1 件 "<kind>\t<id>\t<detail>" を出す。
# コマンド文字列は argv で渡す。`python3 - <<'PY'` はプログラム自体を stdin から
# 読むので、同じ stdin へパイプすると sys.stdin.read() が空になる。
matches="$(python3 - "$cmd" <<'PY' 2>/dev/null || true
import hashlib, re, sys, time

cmd = sys.argv[1]
out = []


def ident(prefix, seed):
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:10]
    return "%s-%s-%s" % (prefix, time.strftime("%Y%m%dT%H%M%S"), digest)


# gh workflow run <wf> — 発射した。conclusion はターンの外で決まる。
for m in re.finditer(r"gh\s+workflow\s+run\s+([^\s;|&]+)", cmd):
    wf = m.group(1)
    out.append(("cd-run", ident("wf", wf + cmd), "gh workflow run %s" % wf))

# gh run watch <id> — 完走待ち。待ちはツール呼び出しの寿命を超えうる。
for m in re.finditer(r"gh\s+run\s+watch\s+(\d+)", cmd):
    rid = m.group(1)
    out.append(("cd-run", "run-%s" % rid, "gh run watch %s" % rid))

# nohup — 明示的にツール呼び出しより長生きさせた。
if re.search(r"(?:^|[;&|]\s*|\s)nohup\s", cmd):
    head = re.sub(r"\s+", " ", cmd).strip()[:120]
    out.append(("generic", ident("nohup", cmd), "nohup: %s" % head))

for kind, ident_, detail in out:
    print("%s\t%s\t%s" % (kind, ident_, detail))
PY
)"
[ -n "$matches" ] || exit 0

while IFS=$'\t' read -r kind ident detail; do
  [ -n "$ident" ] || continue
  bash "$ASYNC_SH" register --id "$ident" --kind "$kind" --detail "$detail" \
    --source posttooluse-auto >/dev/null 2>&1 || continue
  printf '[async-work] 持ち越し登録: %s (%s)\n' "$ident" "$detail" >&2
  if declare -F aidd_ledger_append_record >/dev/null 2>&1; then
    python3 - "$kind" "$ident" "$detail" <<'PY' | while IFS= read -r row; do
import json, sys
kind, ident, detail = sys.argv[1:4]
print(json.dumps({"component": "H1", "event": "measure", "rule": "async-work-registered",
                  "detail": detail,
                  "subject": {"id": ident, "kind": kind, "source": "posttooluse-auto"}},
                 ensure_ascii=False, separators=(",", ":")))
PY
      aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true
    done
  fi
done <<<"$matches"

exit 0
