#!/usr/bin/env bash
# 毎 PR の強制点: **このリポジトリの実物**が vendor スタンプと一致することを確かめる。
# aidd-governance#137。fixture ではなく実ファイルを見るのが本テストの役目である。
#
# tests/test-h5-source-stamp.sh は検査器そのものの反証（合成 fixture）を担う。
# 本テストは「今このリポジトリに置かれている本体が改変されていないか」を見る。
# 分けてあるのは、検査器が壊れても実物が守られていると誤読しないため。
#
# network は使わない。upstream との鮮度は .github/workflows/h5-source-freshness.yml
# が日次で見る（fetch 失敗は緑にしない = exit 2 UNVERIFIED）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== vendor 同一性（offline / network 不要）==="
if bash "$ROOT/scripts/h5-source-check.sh" offline; then
  echo "PASS: 実物の本体がスタンプと一致する"
  exit 0
fi
echo "FAIL: 本体がスタンプと一致しない"
echo "  本体を本リポジトリで直接編集してはならない (aidd-governance#137)。"
echo "  正本 aidd-governance で直し、vendor し直してスタンプも更新すること。"
exit 1
