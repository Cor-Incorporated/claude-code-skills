#!/usr/bin/env bash
# 台帳の 3 つの書き手が、同じ入力から同じ cmd_head を作り、どの行も 1 行 1 JSON
# として読めることを機械的に結ぶ（2026-09-25）。
#
# 書き手:
#   claude : hooks/lib/aidd-ledger.sh の aidd_ledger_append
#            （$HOME/.claude/hooks/ledger/guard-ledger.jsonl）
#   codex  : hooks/codex/protect-branches-codex.sh の ledger_line（CODEX_GUARD_LEDGER）
#   cursor : hooks/cursor/git-guard.sh の ledger_row（$HOME/.cursor/hooks/guard-ledger.jsonl）
#
# cmd_head の規則（先頭 120 バイトを UTF-8 の文字境界で切る、" は '、改行・タブ・
# 復帰は空白、JSON として安全に書く）は 3 か所に手で複製されている。2026-09-25 の
# 実台帳では、Codex は 414 行中 62 行、Cursor は 416 行中 6 行が JSON として読め
# なかった（Claude 側は 2026-09-02 に直したが、\001 などの制御文字は残っていた）。
# 片方だけ直す・片方だけ変えると、台帳どうしの突き合わせや H6 の集計が静かに崩れる。
# コメントで「揃えること」と書く代わりに、同じ事故入力を 3 つに通して比べる。
#
# 反証: どれか 1 つの書き手で改行の空白化・バックスラッシュのエスケープ・制御文字の
# 扱い・UTF-8 境界での切り詰めを外すと、その書き手の名前と 3 者の値を挙げて落ちる。
# 各書き手は別々の sandbox HOME / 台帳パスで動かし、実台帳には触れない。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/hooks/lib/aidd-ledger.sh"
CODEX_HOOK="$ROOT/hooks/codex/protect-branches-codex.sh"
CURSOR_HOOK="$ROOT/hooks/cursor/git-guard.sh"
export AIDD_LEDGER_SOURCE=test

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/claude" "$SB/codex/.codex/hooks" "$SB/cursor/.cursor/hooks" "$SB/fix"
CLAUDE_LEDGER="$SB/claude/.claude/hooks/ledger/guard-ledger.jsonl"
CODEX_LEDGER="$SB/codex/ledger.jsonl"
CURSOR_LEDGER="$SB/cursor/.cursor/hooks/guard-ledger.jsonl"

# 両 hook は cwd の git から current branch を読む。保護ブランチを明示した push を
# 使うので結果は branch に依らないが、周囲の作業ツリーは読ませない。
git -C "$SB/fix" init -q
git -C "$SB/fix" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$SB/fix" checkout -q -b feat/link
git -C "$SB/fix" remote add origin git@github.com:Cor-Incorporated/claude-code-skills.git

# 事故入力（Codex / Cursor の台帳テストと同じ 5 形）。どれも保護ブランチへの
# force push なので、両 hook とも deny して台帳に 1 行書く。
BS="\\"
pad="$(printf '%89s' '' | tr ' ' x)" # 30 バイトの接頭辞 + 89 = 119 バイト目まで
labels=(multi-line tab-and-quote backslash-at-byte-120 utf8-across-byte-120 control-char)
inputs=(
  "git push --force origin main"$'\r\n'"echo second line"
  'git push --force origin "main"'$'\t''# tabbed'
  "git push --force origin main #${pad}${BS}tail"
  "git push --force origin main #${pad}日本語"
  "git push --force origin main # "$'\001'" ctl"
)

for cmd in "${inputs[@]}"; do
  HOME="$SB/claude" bash -c '. "$1" && aidd_ledger_append link-test block link-rule "$2"' \
    _ "$LIB" "$cmd" >/dev/null 2>&1
  jq -cn --arg command "$cmd" '{tool_input:{command:$command}}' \
    | (cd "$SB/fix" && HOME="$SB/codex" CODEX_GUARD_LEDGER="$CODEX_LEDGER" \
      CODEX_SPIKE_LOG="$SB/codex/spike-fire.log" bash "$CODEX_HOOK" >/dev/null 2>&1)
  jq -cn --arg command "$cmd" '{command:$command}' \
    | (cd "$SB/fix" && HOME="$SB/cursor" bash "$CURSOR_HOOK" >/dev/null 2>&1)
done

python3 - "${#inputs[@]}" "$CLAUDE_LEDGER" "$CODEX_LEDGER" "$CURSOR_LEDGER" \
  "${labels[@]}" "${inputs[@]}" <<'PY'
import json, re, sys

n = int(sys.argv[1])
paths = dict(zip(("claude", "codex", "cursor"), sys.argv[2:5]))
labels, inputs = sys.argv[5:5 + n], sys.argv[5 + n:5 + 2 * n]
failures = 0


def expected(cmd):
    head = cmd.encode("utf-8")[:120].decode("utf-8", "ignore")
    return head.replace('"', "'").replace("\n", " ").replace("\t", " ").replace("\r", " ")


def printable(s):  # jq escapes other control chars, printf fallbacks drop them
    return "".join(ch for ch in s if ord(ch) >= 0x20)


heads = {}
for writer, path in paths.items():
    try:
        raw = open(path, "rb").read()
    except OSError as exc:
        print(f"FAIL: {writer} wrote no ledger ({exc.strerror}: {path})")
        failures += 1
        continue
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    recs, broken = [], []
    for i, line in enumerate(lines, 1):
        try:
            rec = json.loads(line.decode("utf-8"))
            if not isinstance(rec, dict) or "cmd_head" not in rec:
                raise ValueError(f"no cmd_head: {rec!r:.60}")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(rec.get("ts"))):
                raise ValueError(f"ts={rec.get('ts')!r}")
            recs.append(rec)
        except Exception as exc:
            broken.append(f"line {i}: {type(exc).__name__}: {exc} | {line[:60]!r}")
    if raw and not raw.endswith(b"\n"):
        broken.append("file does not end with a newline")
    if broken or len(recs) != n:
        print(f"FAIL: {writer} ledger lines={len(lines)} records={len(recs)} expected={n} broken={len(broken)}")
        for b in broken:
            print(f"    {b}")
        failures += 1
        continue
    heads[writer] = [printable(r["cmd_head"]) for r in recs]
    print(f"PASS: {writer} ledger has {n} records, all strict JSON")

for i, (label, cmd) in enumerate(zip(labels, inputs)):
    want = printable(expected(cmd))
    got = {w: h[i] for w, h in heads.items()}
    drift = sorted(w for w, v in got.items() if v != want)
    missing = sorted(set(paths) - set(got))
    if drift or missing:
        why = [f"drift in {','.join(drift)}"] if drift else []
        why += [f"no readable record from {','.join(missing)}"] if missing else []
        values = " ".join(f"{w}={v!r}" for w, v in got.items())
        print(f"FAIL: cmd_head {label}: {'; '.join(why)}: {values} expected={want!r}")
        failures += 1
    else:
        print(f"PASS: cmd_head {label}: {len(got)} writers agree")

print(f"--- link failures={failures} ---")
sys.exit(1 if failures else 0)
PY
