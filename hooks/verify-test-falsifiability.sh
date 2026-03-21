#!/usr/bin/env bash
# verify-test-falsifiability.sh
# PostToolUse hook: テストファイル書き込み後に反証可能性チェックを実行
#
# テストのdocstring/コメントに記載されたバグ意図と、
# 実際のアサーションの乖離を検出して警告する。

set -euo pipefail

# --- 入力: stdin JSON から file_path を取得 ---
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# ファイルが存在しない場合はスキップ
if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

WARNINGS=""

# --- 1. Bug/Issue記述の検出 ---
# docstringやコメントに Bug, 問題, 検出, detect 等が含まれるかチェック
BUG_DESCRIPTIONS=$(grep -niE '(Bug\s*#?\d+|Bug\s*\d+|問題を検出|問題の検出|を検出する|detect|regression|fix.*issue)' "$FILE_PATH" 2>/dev/null || true)

if [[ -n "$BUG_DESCRIPTIONS" ]]; then
  # --- 2. アサーションパターンの分析 ---
  # 下限チェックのみ（>=, >）で上限チェック（<=, <）や分散チェックがないか
  HAS_LOWER_BOUND=$(grep -cE 'assert.*>=|assert.*>' "$FILE_PATH" 2>/dev/null || echo "0")
  HAS_UPPER_BOUND=$(grep -cE 'assert.*<=|assert.*<[^=]' "$FILE_PATH" 2>/dev/null || echo "0")
  HAS_VARIABILITY=$(grep -cE 'std_dev|variance|分散|変動|max.*-.*min|set\(.*\)|len\(set|unique' "$FILE_PATH" 2>/dev/null || echo "0")
  HAS_INEQUALITY=$(grep -cE 'assert.*!=|assertNotEqual' "$FILE_PATH" 2>/dev/null || echo "0")

  if [[ "$HAS_LOWER_BOUND" -gt 0 && "$HAS_UPPER_BOUND" -eq 0 && "$HAS_VARIABILITY" -eq 0 ]]; then
    WARNINGS+="⚠️ 反証可能性リスク: テストにBug記述があるが、下限チェック(>=)のみで上限・変動チェックなし。\n"
    WARNINGS+="  → Bugが存在してもテストがパスする可能性あり。\n"
    WARNINGS+="  → 上限チェック(<=)、変動チェック(max-min)、不等チェック(!=)の追加を検討。\n"
  fi

  # --- 3. 均一性チェックの欠如 ---
  HAS_MULTIPLE_RUNS=$(grep -cE 'parametrize|for.*in.*range|multiple.*run|複数回|異なる.*パターン' "$FILE_PATH" 2>/dev/null || echo "0")

  if [[ "$HAS_MULTIPLE_RUNS" -eq 0 && "$HAS_VARIABILITY" -eq 0 ]]; then
    WARNINGS+="⚠️ 均一性チェック欠如: Bug検出を宣言しているが、異なる入力での変動確認がない。\n"
    WARNINGS+="  → 異なる回答パターン/入力で結果が変動するか確認するテストを検討。\n"
  fi

  # --- 4. docstring意図とassert内容の乖離チェック ---
  # 「固定」「機械的」「変動」等のキーワードがdocstringにあるが、変動チェックがない
  HAS_VARIABILITY_INTENT=$(grep -ciE '固定|機械的|変動|ばらつき|adaptive|dynamic|vary|variable' "$FILE_PATH" 2>/dev/null || echo "0")

  if [[ "$HAS_VARIABILITY_INTENT" -gt 0 && "$HAS_VARIABILITY" -eq 0 && "$HAS_INEQUALITY" -eq 0 ]]; then
    WARNINGS+="⚠️ 意図-アサーション乖離: docstringに「固定/変動」の記述があるが、変動を検証するアサーションがない。\n"
    WARNINGS+="  → max()-min() >= N, len(set(values)) > 1 等の変動アサーション追加を検討。\n"
  fi
fi

# --- 結果出力 ---
if [[ -n "$WARNINGS" ]]; then
  echo "🔍 テスト反証可能性チェック: $(basename "$FILE_PATH")"
  echo ""
  echo -e "$WARNINGS"
  echo ""
  echo "Bug記述箇所:"
  echo "$BUG_DESCRIPTIONS" | head -5
  echo ""
  echo "📖 ルール: ~/.claude/rules/test-falsifiability.md"
  echo "💡 深い検証が必要なら: /test-falsify を実行"
  # 警告のみ、ブロックはしない（exit 0）
  exit 0
fi

exit 0
