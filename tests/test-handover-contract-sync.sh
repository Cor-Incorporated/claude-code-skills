#!/bin/bash
# リンクテスト: 委任契約の欄名を「正本 SKILL.md」「受領側 3 ツール」「発行済ハンドオーバー」で機械照合する
#
# 発端（2026-08-11 cross-tool-scope-collapse）:
#   skills/handover/SKILL.md は「欄名は受領側（Codex / Cursor / OpenCode AGENTS・rules）と
#   一字一句一致させること」と要求している。既存 6 欄はその規律を守っていた。
#   ところが監督が本セッションで追加した 2 欄（完了条件の検査 / 追加を提案しない）は
#   4 通のハンドオーバーで使われながら、正本にも受領側 3 ツールにも 1 箇所も存在しなかった。
#   受領側は「定義を持たない欄名」を渡されていた。
#
# 2 方向を見る理由:
#   方向1（正本→受領）だけでは監督の実際の失敗を検出できない。
#   監督は正本を経由せずハンドオーバーに直接欄を足した。方向2 がそれを捕まえる。
#
# なぜ「コメントで keep in sync」ではだめか:
#   同じ事実が 5 箇所にある（C12）。片方を変えたら落ちるテストでなければ乖離は検出できない。
#   本テストは **不一致のとき両側の値を出して落ちる**（F3 両側照合）。
set -uo pipefail
# 日本語の欄名を扱うため UTF-8 ロケールを固定する。
# 未設定（C ロケール）だと sed の文字クラスがマルチバイトの途中で切れ、
# bash も `${field}」` を 1 つの変数名として解釈して落ちる（2026-08-11 実測）。
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$SCRIPT_DIR/../skills/handover/SKILL.md"
CURSOR_GLOB="$HOME/.cursor/rules"
CURSOR_CAT="$(mktemp)"
trap 'rm -f "$CURSOR_CAT"' EXIT

declare -a RECEIVERS=(
  "Codex:$HOME/.codex/AGENTS.md"
  "OpenCode:$HOME/.config/opencode/AGENTS.md"
)
HANDOVER_DIR="$HOME/Developer/aidd-governance/design/ops/handover"

PASS=0; FAIL=0

# 正本から欄名を抽出。範囲は `## 委任契約` 節の中だけ（次の `##` の手前まで）。
# 欄名は `N. ` / `N. [Pn] ` の直後から最初の区切り（: ： （ ( 空白）まで。
extract_canon_fields() {
  awk '/^## 委任契約/{f=1;next} f&&/^## /{exit} f' "$CANON" 2>/dev/null \
    | grep -E '^[0-9]+\. ' \
    | sed -E 's/^[0-9]+\. *(\[P[0-9]+\] *)?//' \
    | sed -E 's/(:|：|（|\().*$//' \
    | sed -E 's/ .*$//; s/ *$//' | grep -v '^$'
}

# ハンドオーバーから欄名を抽出。**委任契約の表の中だけ**を見る。
# 見出し `## ... 委任契約 ...` から次の `## ` までの `| **<欄名>** |` 行に限定する。
# （全表の第1列を拾うと R4【HIGH】等を欄名と誤認して偽陽性が爆発する — 2026-08-11 実測）
extract_handover_fields() {
  local file="$1"
  awk '/^#+ .*委任契約/{f=1;next} f&&/^#+ /{exit} f' "$file" 2>/dev/null \
    | grep -oE '^\| \*\*[^*]+\*\* \|' \
    | sed -E 's/^\| \*\*//; s/\*\* \|$//' \
    | sed -E 's/^★ *//; s/（新設）$//' \
    | sed -E 's/ *$//' | grep -v '^$'
}

# 表記ゆれの宣言（正本の長い欄名 ⇔ 受領側の短縮形）。
# 2026-08-11 実測: 受領側 3 ツールは短縮形を使っており、これは乖離ではない。
# ただし **宣言した別名だけを許す**。無断の改名は依然として FAIL になる。
alias_of() {
  case "$1" in
    "停止条件と最大反復")         echo "停止条件" ;;
    "発射前の実現可能性チェック")  echo "実現可能性" ;;
    "反証可能な完了条件")         echo "完了条件" ;;
    "人間ゲート列挙")             echo "人間ゲート" ;;
    "事前スパイク回答欄")         echo "事前スパイク" ;;
    "強制点の実測表")             echo "強制点" ;;
    *)                             echo "" ;;
  esac
}

# 逆方向の別名（ハンドオーバーの短縮形 → 正本の長い欄名）
canon_alias_of() {
  case "$1" in
    "停止条件")      echo "停止条件と最大反復" ;;
    "実現可能性チェック") echo "発射前の実現可能性チェック" ;;
    "完了条件")      echo "反証可能な完了条件" ;;
    "人間ゲート")    echo "人間ゲート列挙" ;;
    "事前スパイク")  echo "事前スパイク回答欄" ;;
    "強制点")        echo "強制点の実測表" ;;
    *)               echo "" ;;
  esac
}

hit_count() {  # <needle> <file> [alias]
  local n a
  n=$(grep -c -- "$1" "$2" 2>/dev/null) || n=0
  if [ "$n" -eq 0 ] && [ -n "${3:-}" ]; then
    n=$(grep -c -- "$3" "$2" 2>/dev/null) || n=0
  fi
  echo "$n"
}

check_field() {
  local field="$1" name="$2" path="$3" n
  if [ ! -e "$path" ]; then
    echo "  SKIP: $name ($path 不在 — CI 環境)"; return
  fi
  n=$(hit_count "$field" "$path" "$(alias_of "$field")")
  if [ "$n" -gt 0 ]; then
    echo "  PASS: 「${field}」 $name=$n 箇所"; PASS=$((PASS + 1))
  else
    echo "  FAIL: 「${field}」 正本(SKILL.md)=定義あり / $name($path)=0 箇所 — 受領側に欄名が無い"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== handover 委任契約 欄名の横断同期 (F3 両側照合) ==="
echo "正本: $CANON"
echo ""

# --- 方向1: 正本 → 受領側 3 ツール ---
echo "--- 方向1: 正本の欄名 → 受領側 3 ツールに定義があるか ---"
mapfile -t FIELDS < <(extract_canon_fields)
if [ "${#FIELDS[@]}" -eq 0 ]; then
  echo "  FAIL: 正本から欄名を 1 つも抽出できなかった（抽出規則が正本の書式と乖離）"
  exit 1
fi
echo "  抽出: ${#FIELDS[@]} 欄 — ${FIELDS[*]}"
for field in "${FIELDS[@]}"; do
  for r in "${RECEIVERS[@]}"; do
    check_field "$field" "${r%%:*}" "${r#*:}"
  done
  if [ -d "$CURSOR_GLOB" ]; then
    cat "$CURSOR_GLOB"/*.mdc > "$CURSOR_CAT" 2>/dev/null
    check_field "$field" "Cursor" "$CURSOR_CAT"
  else
    echo "  SKIP: Cursor ($CURSOR_GLOB 不在 — CI 環境)"
  fi
done

# --- 方向2: 発行済ハンドオーバー → 正本 ---
echo ""
echo "--- 方向2: ハンドオーバーで使用した欄名 → 正本に定義があるか ---"
if [ ! -d "$HANDOVER_DIR" ]; then
  echo "  SKIP: $HANDOVER_DIR 不在（CI 環境）"
else
  used=$(for f in "$HANDOVER_DIR"/*.md; do extract_handover_fields "$f"; done | sort -u)
  if [ -z "$used" ]; then
    echo "  (委任契約表を持つハンドオーバーが無い)"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      n=$(hit_count "$f" "$CANON" "$(canon_alias_of "$f")")
      if [ "$n" -gt 0 ]; then
        echo "  PASS: 「${f}」 正本=$n 箇所"; PASS=$((PASS + 1))
      else
        echo "  FAIL: 「${f}」 ハンドオーバー=使用あり / 正本(SKILL.md)=0 箇所 — 定義の無い欄を受領側に渡している"
        FAIL=$((FAIL + 1))
      fi
    done <<< "$used"
  fi
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
# 本テストはローカル環境の監査である。CI には ~/.codex 等が無く全 SKIP になり、
# PASS=0 FAIL=0 で exit 0 する。**その緑を「同期済み」と読まないこと。**
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
  echo "NOTICE: 検査対象が 1 つも存在しなかった（CI 環境）。本結果は同期の証明ではない。"
fi
[ "$FAIL" -eq 0 ] || exit 1
