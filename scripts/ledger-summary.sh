#!/usr/bin/env bash
# T10-2: 防御台帳の集計器（計測器・凍結対象外）
#
# 出力: 一次台帳の全件数 / source=real / source=test / source欄なし（=導入前） /
# third-party guardrail fire / 合算全件数
# 既存データは遡及分類しない。「source欄なし」を独立の列として出す。
# third-party は claude-code-harness 5.7.0 の project-local 監査ログ
# (.claude/state/audit/guardrail-fires.jsonl) を別母集団のまま集計する。
# 複数リポを集約する場合は AIDD_THIRD_PARTY_LEDGER_PATHS に os.pathsep
# (macOS/Linux は :) 区切りで明示する。未指定時は現在ディレクトリ配下だけを見る。
# バースト（同一秒 5 件以上）の行数も併せて出す（汚染の可視化 — 除去はしない）。
set -uo pipefail

LEDGER="${AIDD_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"
THIRD_PARTY_LEDGER_PATHS="${AIDD_THIRD_PARTY_LEDGER_PATHS:-$PWD/.claude/state/audit/guardrail-fires.jsonl}"
if [[ ! -f "$LEDGER" ]]; then
  echo "ledger not found: $LEDGER" >&2
  exit 1
fi

python3 - "$LEDGER" "$THIRD_PARTY_LEDGER_PATHS" <<'PY'
import json, os, sys
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

# third-party の raw command/path は読まず、plugin が公開する schema 行だけを数える。
# real/test/none の凍結母集団を壊さないため legacy total は一次台帳のまま維持し、
# 合算値は total_with_third_party として別に出す。
third_party_paths = []
seen = set()
for candidate in sys.argv[2].split(os.pathsep):
    candidate = candidate.strip()
    if not candidate:
        continue
    normalized = os.path.realpath(candidate)
    if normalized in seen:
        continue
    seen.add(normalized)
    if os.path.isfile(normalized):
        third_party_paths.append(normalized)

third_party = 0
for audit_path in third_party_paths:
    with open(audit_path, encoding="utf-8", errors="replace") as audit_file:
        for line in audit_file:
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get("schema_version") == "guardrail-fire.v1":
                third_party += 1

# バースト: 同一 ts（秒精度）に 5 件以上含まれる行数の合計
ts = Counter(r.get("ts", "") for r in rows)
burst_ts = {t for t, n in ts.items() if n >= 5}
burst_rows = sum(n for t, n in ts.items() if t in burst_ts)

print(f"total={total}")
print(f"source_real={real}")
print(f"source_test={test}")
print(f"source_none={no_source}")
print(f"source_third_party={third_party}")
print(f"total_with_third_party={total + third_party}")
print(f"third_party_files={len(third_party_paths)}")
print(f"burst_rows={burst_rows} ({burst_rows*100/total:.1f}% of total)" if total else "burst_rows=0")
PY
