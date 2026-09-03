#!/usr/bin/env bash
# 毎 PR の強制点: **このリポジトリの実物**がスタンプの sha256 と一致すること。
# aidd-governance#137。fixture ではなく実ファイルを見るのが本テストの役目である。
#
# このリポジトリは正本 (role=source) なので、本テストが守るのは
# 「**公開している sha256 と本体がずれていない**」ことである。本体を直して
# スタンプを直し忘れると、vendor 先は古い sha を正だと信じて照合し続ける。
# その事故をここで止める。
#
# tests/test-h5-source-stamp.sh は検査器そのものの反証（合成 fixture）を担う。
# 分けてあるのは、検査器が壊れても実物が守られていると誤読しないため。
# network は使わない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== 正本の同一性（offline / network 不要）==="
if bash "$ROOT/scripts/h5-source-check.sh" offline; then
  echo "PASS: 本体が公開スタンプと一致する"
else
  echo "FAIL: 本体とスタンプがずれている"
  echo "  本体を変えたら scripts/h5-admission-check.source の sha256 も同じ commit で更新すること。"
  echo "  更新しないと vendor 先が古い sha を正として照合し続ける (aidd-governance#137)。"
  exit 1
fi
# aidd-governance#144 — 被覆範囲の宣言 ↔ 強制の対。
# **ここが宣言側**である。スタンプ (強制側) から sha256:<path> 行を 1 本消すと
# 集合が食い違って落ちる。被覆が黙って縮むのを止めるのが役目。
#
# 覆うのは judgment を決めるものだけ。judgment を検証するテスト群は覆わない
# （本体が byte 固定なので両リポの判定は一致したまま。根拠はスタンプの
# ヘッダに書いてある）。
EXPECTED_COVERAGE="scripts/h5-source-check.sh
.aidd-h5-vendor-lint
scripts/h5-vendor-lint.sh"

echo "=== 被覆範囲が宣言と一致すること (#144) ==="
ACTUAL_COVERAGE="$(grep -E '^sha256:' "$ROOT/scripts/h5-admission-check.source" \
  | sed -E 's/^sha256:(.*)=[0-9a-f]{64}$/\1/' | sort)"
if [[ "$ACTUAL_COVERAGE" == "$(printf '%s\n' "$EXPECTED_COVERAGE" | sort)" ]]; then
  echo "PASS: 追加被覆が宣言と一致する"
  printf '  covered: %s\n' "$ACTUAL_COVERAGE"
else
  # runbook.md rule B: 両方の値を挙げて落ちる。「不一致」だけでは直せない。
  echo "FAIL: 追加被覆が宣言と食い違っている"
  echo "  expected = [$(printf '%s' "$EXPECTED_COVERAGE" | tr '\n' ' ')]"
  echo "  actual   = [$(printf '%s' "$ACTUAL_COVERAGE" | tr '\n' ' ')]"
  echo "  被覆を変えるなら、この宣言とスタンプの両方を同じ commit で更新すること。"
  exit 1
fi

echo "=== 正本で online を配線していないこと（上流が無いのに緑にしない）==="
set +e
bash "$ROOT/scripts/h5-source-check.sh" online >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
  echo "PASS: 正本での online は誤用として red (exit $rc)"
  exit 0
fi
echo "FAIL: 正本での online が red にならない (exit $rc)"
exit 1
