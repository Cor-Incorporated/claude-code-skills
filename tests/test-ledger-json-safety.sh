#!/usr/bin/env bash
# 台帳の 1 行が必ず JSON として読めることを検査する。
#
# 起点事故 (2026-09-02): 実台帳 5643 行のうち 3 行が
#   json.JSONDecodeError: Invalid \escape
# で読めなくなっていた。原因は cmd_head の組み立てが引用符を「置換」する一方で
# バックスラッシュを「エスケープ」していなかったこと。事故入力は普通のコマンドで、
#   grep -n 'cmd_norm\|sed -E' ~/.cursor/hooks/
# のような alternation を含む grep なら誰でも打つ。
#
# なぜ重いか: 読めない行は ledger-summary.sh の集計から丸ごと落ちる。
# 台帳は「この防御が実際に発火したか」の唯一の証拠であり、H6 の退役判定
# （90 日発火ゼロ）はこの数を読む。壊れた行は「発火しなかった」と同じに見える。
# つまり黙って防御を殺す方向へ倒れる。
#
# 反証可能性: バックスラッシュ倍化を削った変異体で同じ入力を書かせ、壊れることを
# 実測する。壊れないなら、この処理は最初から効いていない。
#
# 全て $TMPDIR の HOME サンドボックスで走る。実台帳には触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/hooks/lib/aidd-ledger.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# 事故入力。ここに置く値は「実際に台帳を壊した形」を含むこと。
write_probe() { # $1 = lib path to load, $2 = HOME sandbox
  mkdir -p "$2/.claude/hooks/lib"
  cp "$1" "$2/.claude/hooks/lib/aidd-ledger.sh"
  cat > "$2/probe.sh" <<'EOS'
#!/usr/bin/env bash
set -u
. "$HOME/.claude/hooks/lib/aidd-ledger.sh"
export AIDD_LEDGER_SOURCE=test
BS='\'
# 1: 実際に台帳を壊した形（grep の alternation）
aidd_ledger_append test-hook block test-rule "grep -n 'cmd_norm${BS}|sed -E' ~/.cursor/hooks/"
# 2: Windows 風パス + 引用符 + タブ
aidd_ledger_append test-hook block test-rule "path C:${BS}Users${BS}x and a quote \" and	a tab"
# 3: 末尾バックスラッシュ（切り詰めで生まれうる最悪形）
aidd_ledger_append test-hook block test-rule "trailing backslash ${BS}"
# 4: 非 ASCII と混在（UTF-8 切り詰めとの相互作用）
aidd_ledger_append test-hook block test-rule "日本語も混ぜる ${BS}n リテラル ${BS}${BS} 二重"
# 5: 改行入り
aidd_ledger_append test-hook block test-rule "first line
second line"
EOS
  HOME="$2" bash "$2/probe.sh" >/dev/null 2>&1
}

count_broken() { # $1 = HOME sandbox -> "<rows> <broken>"
  python3 - "$1/.claude/hooks/ledger/guard-ledger.jsonl" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("0 0"); raise SystemExit(0)
rows = broken = 0
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    rows += 1
    try:
        json.loads(line)
    except Exception:
        broken += 1
print(f"{rows} {broken}")
PY
}

echo "=== 1. 事故入力を書いても全行が JSON として読める ==="
GOOD="$SB/good"
write_probe "$LIB" "$GOOD"
read -r rows broken <<<"$(count_broken "$GOOD")"
if [[ "$rows" -ge 5 && "$broken" -eq 0 ]]; then
  ok "書いた $rows 行すべてが JSON として読める（破損 0）"
else
  bad "台帳に読めない行がある" "rows=$rows broken=$broken"
fi

echo
echo "=== 2. 値が失われていない（潰しすぎていない） ==="
python3 - "$GOOD/.claude/hooks/ledger/guard-ledger.jsonl" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except Exception:
        pass
heads = [r.get("cmd_head", "") for r in rows]
checks = [
    ("alternation が残る", any("cmd_norm" in h and "sed -E" in h for h in heads)),
    ("バックスラッシュが残る", any("\\" in h for h in heads)),
    ("非 ASCII が残る", any("日本語" in h for h in heads)),
    ("改行は空白へ寄せられる", all("\n" not in h for h in heads)),
    ("生の二重引用符は残らない", all('"' not in h for h in heads)),
]
for label, good in checks:
    print(f"{'PASS' if good else 'FAIL'}: {label}")
raise SystemExit(0 if all(g for _, g in checks) else 1)
PY
if [[ $? -eq 0 ]]; then
  pass=$((pass + 5))
else
  fail=$((fail + 1))
  echo "    値の保存/正規化に失敗"
fi

echo
echo "=== 3. 反証: バックスラッシュ倍化を外すと壊れるか ==="
MUT="$SB/mutant-lib.sh"
python3 - "$LIB" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = "| sed 's/\\\\/\\\\\\\\/g'"
n = text.count(needle)
if n == 0:
    raise SystemExit("mutation target not found: backslash doubling absent")
pathlib.Path(dst).write_text(text.replace(needle, ""))
print(f"    変異: バックスラッシュ倍化を {n} 箇所削除")
PY
if [[ -f "$MUT" ]]; then
  BADSB="$SB/mutant"
  write_probe "$MUT" "$BADSB"
  read -r mrows mbroken <<<"$(count_broken "$BADSB")"
  if [[ "$mbroken" -gt 0 ]]; then
    ok "変異体は $mrows 行中 $mbroken 行を壊す = エスケープが結論を作っていた"
  else
    bad "変異体でも壊れない = このテストはエスケープを証明していない" "rows=$mrows broken=$mbroken"
  fi
else
  bad "変異体を作れなかった — 反証不能" "mutation target missing"
fi

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
