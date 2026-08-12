#!/usr/bin/env bash
# T10-2: 防御台帳の集計器（計測器・凍結対象外）
#
# 出力: 全件数 / source=real / source=test / source欄なし（=導入前）
# 既存データは遡及分類しない。「source欄なし」を独立の列として出す。
# バースト（同一秒 5 件以上）の行数も併せて出す（汚染の可視化 — 除去はしない）。
set -uo pipefail

LEDGER="${AIDD_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"
if [[ ! -f "$LEDGER" ]]; then
  echo "ledger not found: $LEDGER" >&2
  exit 1
fi

python3 - "$LEDGER" <<'PY'
import json, sys
from collections import Counter

path = sys.argv[1]
rows = []
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        rows.append(json.loads(line))
    except Exception:
        rows.append({})

total = len(rows)
real = sum(1 for r in rows if r.get("source") == "real")
test = sum(1 for r in rows if r.get("source") == "test")
no_source = sum(1 for r in rows if "source" not in r)

# バースト: 同一 ts（秒精度）に 5 件以上含まれる行数の合計
ts = Counter(r.get("ts", "") for r in rows)
burst_ts = {t for t, n in ts.items() if n >= 5}
burst_rows = sum(n for t, n in ts.items() if t in burst_ts)

print(f"total={total}")
print(f"source_real={real}")
print(f"source_test={test}")
print(f"source_none={no_source}")
print(f"burst_rows={burst_rows} ({burst_rows*100/total:.1f}% of total)" if total else "burst_rows=0")
PY
