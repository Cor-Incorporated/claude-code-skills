#!/usr/bin/env bash
# シェル変数の直後に非 ASCII 文字を置く形（`$var）` / `$var（`）を禁じる。
#
# ## なぜ機械照合にするか
#
# 2026-09-03 の同一セッションで **3 回**踏んだ。
#
#   1. 監督のプローブ `probe93.sh`      — `rc=${rc}` を `rc=$rc（` と書いて異常終了
#   2. 監督のプローブ `probe-wrapper.sh` — 同じ形。変異テストが空振りした
#   3. **出荷したフック** `persona-village-v2/scripts/aidd-h16-precommit.sh:70`
#      — `set -u` 下で `hook?: unbound variable` により **rc=1**。
#        commit 時に走るフックなので、その分岐に入ると
#        **無関係な理由で commit がブロックされる。**
#
# 掃いたところ 3 リポジトリに 6 箇所あり、**全部が失敗経路 / skip 経路**だった。
# 成功しているあいだは決して実行されないので、テストが緑でも生き残る。
# `~/.claude/rules/quality.md`「同型 fix 3 回目は個別修正をやめる」に該当する。
#
# ## なぜ壊れるか
#
# bash の変数名は `[A-Za-z_][A-Za-z0-9_]*` で終わるはずだが、macOS の bash 3.2 は
# 続く多バイト文字のバイト列を名前の一部として読む。`LC_ALL=en_US.UTF-8` でも同じ
# （実測）。`${var}` と書けば常に正しい。
#
# ## 判定
#
# `$name` の直後が非 ASCII バイトなら fail。コメント行は除く（実行されないため）。
# 誤検知は原理的に無い —— 該当する書き方は「今壊れている」か「移植で壊れる」の
# どちらかであって、正しい用例が存在しない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

scan() { # $1=repo root -> 違反行を stdout（"path:line:抜粋"）
  python3 - "$1" <<'PY'
import os, pathlib, re, subprocess, sys
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])')
root = pathlib.Path(sys.argv[1])
try:
    files = subprocess.run(["git", "-C", str(root), "ls-files", "*.sh"],
                           capture_output=True, text=True, timeout=120).stdout.split("\n")
except Exception as e:                      # 取得失敗は「違反ゼロ」と読ませない
    print(f"SCAN-ERROR:{e}")
    raise SystemExit(2)
for f in files:
    if not f:
        continue
    p = root / f
    try:
        txt = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for i, line in enumerate(txt.split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        m = pat.search(line)
        if m:
            print(f"{f}:{i}:{line[max(0, m.start() - 20):m.end() + 4].strip()}")
PY
}

echo "=== 前提: 走査器が実際にファイルを見ているか（空振り検査） ==="
n_files="$(git -C "$ROOT" ls-files '*.sh' | wc -l | tr -d ' ')"
if [[ "$n_files" -ge 20 ]]; then
  ok "走査対象 ${n_files} 本（0 本なら以降は無意味）"
else
  bad "走査対象が ${n_files} 本しかない — glob か repo が想定と違う"
fi

echo ""
echo "=== 陽性対照: 既知の事故入力を検出するか ==="
mkdir -p "$WORK/pos"
git -C "$WORK/pos" init -q
cat > "$WORK/pos/bad.sh" <<'EOS'
#!/usr/bin/env bash
set -u
echo "見つからない（$hook）— skip"
EOS
git -C "$WORK/pos" add -A >/dev/null 2>&1
found="$(scan "$WORK/pos")"
if [[ "$found" == *"bad.sh:3"* ]]; then
  ok "事故入力を行番号つきで検出する"
else
  bad "検出しない :: ${found:-（出力なし）}"
fi

echo ""
echo "=== 陰性対照: 正しい書き方を撃たない ==="
mkdir -p "$WORK/neg"
git -C "$WORK/neg" init -q
cat > "$WORK/neg/good.sh" <<'EOS'
#!/usr/bin/env bash
set -u
echo "見つからない（${hook}）— skip"
echo "$hook は空白区切りなので安全"
# コメント行の $hook） は実行されないので対象外
EOS
git -C "$WORK/neg" add -A >/dev/null 2>&1
found="$(scan "$WORK/neg")"
if [[ -z "$found" ]]; then
  ok "\${var} / 空白区切り / コメント行は撃たない"
else
  bad "正しい書き方を撃った :: $found"
fi

echo ""
echo "=== 本番: このリポジトリに違反が無いこと ==="
violations="$(scan "$ROOT")"
if [[ "$violations" == SCAN-ERROR:* ]]; then
  bad "走査自体が失敗した（違反ゼロと読んではならない）:: $violations"
elif [[ -z "$violations" ]]; then
  ok "違反 0 件"
else
  bad "違反が残っている:"
  printf '%s\n' "$violations" | sed 's/^/      /'
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
