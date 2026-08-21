#!/bin/bash
# リンクテスト: Route B/C の既存 10 欄、H8 補助 7 欄、
# Phase 20 の可視化文面、Phase 21 の H5 書式節を両側照合する。
#
# デフォルトはこの repo 内の正本 ↔ Claude rule を検査する。
# HANDOVER_SYNC_CROSS_REPO=1 で aidd payload 3 本と OpenCode profile、
# HANDOVER_SYNC_DEPLOYED=1 で home 配備 3 面をそれぞれ別計数する。
# HANDOVER_SYNC_TOOL=codex|cursor|opencode で自レーンだけを検査できる。
# 対象の無い CI での SKIP は「同期済み」に数えない。
set -uo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANON="$ROOT/skills/handover/SKILL.md"
CLAUDE_RULE="$ROOT/rules/delegation.md"
AIDD_ROOT="${AIDD_GOVERNANCE_ROOT:-$HOME/Developer/aidd-governance}"
OPENCODE_PROFILE="${OPENCODE_PROFILE_PATH:-$HOME/Developer/opencode/packages/guardrails/profile/AGENTS.md}"
HANDOVER_DIR="${HANDOVER_DIR:-$HOME/Developer/aidd-governance/design/ops/handover}"
CODEX_DEPLOYED="${CODEX_DEPLOYED_PATH:-$HOME/.codex/AGENTS.md}"
OPENCODE_DEPLOYED="${OPENCODE_DEPLOYED_PATH:-$HOME/.config/opencode/AGENTS.md}"
CURSOR_RULES="${CURSOR_RULES_DIR:-$HOME/.cursor/rules}"
SYNC_TOOL="${HANDOVER_SYNC_TOOL:-all}"
SYNC_TMP="$(mktemp -d)"
trap 'rm -rf "$SYNC_TMP"' EXIT

case "$SYNC_TOOL" in
  all|codex|cursor|opencode) ;;
  *) echo "FAIL: unknown HANDOVER_SYNC_TOOL=$SYNC_TOOL"; exit 2 ;;
esac

wants_tool() {
  [ "$SYNC_TOOL" = "all" ] || [ "$SYNC_TOOL" = "$1" ]
}

PASS=0
FAIL=0
SKIP=0

extract_canon_fields() {
  awk '/^## 委任契約/{f=1;next} f&&/^## /{exit} f' "$CANON" 2>/dev/null \
    | grep -E '^[0-9]+\. ' \
    | sed -E 's/^[0-9]+\. *(\[P[0-9]+\] *)?//' \
    | sed -E 's/(:|：|（|\().*$//' \
    | sed -E 's/ *$//' | grep -v '^$'
}

extract_h8_fields() {
  awk '/^## H8 発射前補助欄/{f=1;next} f&&/^## /{exit} f' "$CANON" 2>/dev/null \
    | grep -E '^[0-9]+\. ' \
    | sed -E 's/^[0-9]+\. *//' \
    | sed -E 's/(:|：|（|\().*$//' \
    | sed -E 's/ *$//' | grep -v '^$'
}

extract_handover_fields() {
  local file="$1"
  awk '/^#+ .*委任契約/{f=1;next} f&&/^#+ /{exit} f' "$file" 2>/dev/null \
    | grep -oE '^\| \*\*[^*]+\*\* \|' \
    | sed -E 's/^\| \*\*//; s/\*\* \|$//' \
    | sed -E 's/^★ *//; s/（新設）$//' \
    | sed -E 's/ *$//' | grep -v '^$'
}

canon_alias_of() {
  case "$1" in
    "停止条件") echo "停止条件と最大反復" ;;
    "実現可能性チェック") echo "発射前の実現可能性チェック" ;;
    "完了条件") echo "反証可能な完了条件" ;;
    "人間ゲート") echo "人間ゲート列挙" ;;
    "事前スパイク") echo "事前スパイク回答欄" ;;
    "強制点") echo "強制点の実測表" ;;
    *) echo "" ;;
  esac
}

field_present() {
  local field="$1" path="$2"
  grep -Fq -- "$field" "$path" 2>/dev/null
}

check_field() {
  local family="$1" field="$2" name="$3" path="$4"
  if [ ! -f "$path" ]; then
    echo "  SKIP: ${family}「${field}」 $name ($path 不在)"
    SKIP=$((SKIP + 1))
    return 0
  fi
  if field_present "$field" "$path"; then
    echo "  PASS: ${family}「${field}」 ${name}=定義あり"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${family}「${field}」 正本=定義あり / ${name}($path)=定義なし"
    FAIL=$((FAIL + 1))
  fi
}

check_source_all_fields() {
  local name="$1" path="$2" field count
  count=0
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    check_field "委任契約" "$field" "$name" "$path"
    count=$((count + 1))
  done < <(extract_canon_fields)
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    check_field "H8補助欄" "$field" "$name" "$path"
    count=$((count + 1))
  done < <(extract_h8_fields)
  if [ "$count" -ne 17 ]; then
    echo "  FAIL: 正本から抽出した欄数=$count / 期待=17（10+7）"
    FAIL=$((FAIL + 1))
  fi
}

extract_named_section() {
  local path="$1" heading="$2"
  awk -v heading="$heading" '
    $0 == heading { found=1; active=1 }
    active && /^## / && $0 != heading { exit }
    active { lines[++n]=$0; if ($0 != "") last=n }
    END {
      if (!found) exit 2
      for (i=1; i<=last; i++) print lines[i]
    }
  ' "$path" 2>/dev/null
}

compare_named_section() {
  local key="$1" heading="$2" name="$3" path="$4"
  local expected="$SYNC_TMP/${key}.expected" actual="$SYNC_TMP/${key}.${name}.actual"
  if [ ! -f "$path" ]; then
    echo "  SKIP: $heading $name ($path 不在)"
    SKIP=$((SKIP + 1))
    return 0
  fi
  if ! extract_named_section "$CLAUDE_RULE" "$heading" >"$expected"; then
    echo "  FAIL: $heading Claude rule の正本節が無い"
    FAIL=$((FAIL + 1))
    return 0
  fi
  if ! extract_named_section "$path" "$heading" >"$actual"; then
    echo "  FAIL: $heading $name($path) に同名節が無い"
    FAIL=$((FAIL + 1))
    return 0
  fi
  if cmp -s "$expected" "$actual"; then
    echo "  PASS: $heading Claude rule == $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $heading Claude rule != ${name}（両側の SHA-256 と diff）"
    shasum -a 256 "$expected" "$actual" | sed 's/^/    /'
    diff -u "$expected" "$actual" | sed 's/^/    /' || true
    FAIL=$((FAIL + 1))
  fi
}

extract_present_contract_fields() {
  local path="$1" field
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    field_present "$field" "$path" && printf '%s\n' "$field"
  done < <(extract_canon_fields)
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    field_present "$field" "$path" && printf '%s\n' "$field"
  done < <(extract_h8_fields)
}

compare_contract_field_set() {
  local key="$1" left_name="$2" left_path="$3" right_name="$4" right_path="$5"
  local left="$SYNC_TMP/${key}.left" right="$SYNC_TMP/${key}.right"
  local left_count right_count
  if [ ! -f "$left_path" ] || [ ! -f "$right_path" ]; then
    echo "  SKIP: 契約欄同期 $left_name ↔ $right_name（片側不在）"
    SKIP=$((SKIP + 1))
    return 0
  fi
  extract_present_contract_fields "$left_path" >"$left"
  extract_present_contract_fields "$right_path" >"$right"
  left_count="$(wc -l <"$left" | tr -d ' ')"
  right_count="$(wc -l <"$right" | tr -d ' ')"
  if [ "$left_count" -eq 17 ] && [ "$right_count" -eq 17 ] && cmp -s "$left" "$right"; then
    echo "  PASS: 契約欄同期 $left_name(17) == $right_name(17)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 契約欄同期 $left_name($left_count) != $right_name($right_count)（両側の値）"
    sed "s/^/    $left_name: /" "$left"
    sed "s/^/    $right_name: /" "$right"
    diff -u "$left" "$right" | sed 's/^/    /' || true
    FAIL=$((FAIL + 1))
  fi
}

compare_section_pair() {
  local key="$1" heading="$2" left_name="$3" left_path="$4" right_name="$5" right_path="$6"
  local left="$SYNC_TMP/${key}.left-section" right="$SYNC_TMP/${key}.right-section"
  if [ ! -f "$left_path" ] || [ ! -f "$right_path" ]; then
    echo "  SKIP: $heading $left_name ↔ $right_name（片側不在）"
    SKIP=$((SKIP + 1))
    return 0
  fi
  if ! extract_named_section "$left_path" "$heading" >"$left"; then
    echo "  FAIL: $heading $left_name($left_path) に同名節が無い"
    FAIL=$((FAIL + 1))
    return 0
  fi
  if ! extract_named_section "$right_path" "$heading" >"$right"; then
    echo "  FAIL: $heading $right_name($right_path) に同名節が無い"
    FAIL=$((FAIL + 1))
    return 0
  fi
  if cmp -s "$left" "$right"; then
    echo "  PASS: $heading $left_name == $right_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $heading $left_name != $right_name（両側の SHA-256 と diff）"
    shasum -a 256 "$left" "$right" | sed 's/^/    /'
    diff -u "$left" "$right" | sed 's/^/    /' || true
    FAIL=$((FAIL + 1))
  fi
}

echo "=== handover 契約・H8・可視化文面の横断同期 ==="
echo "正本: $CANON"
echo ""

echo "--- 方向1: 正本 10+7 → Claude version-controlled rule ---"
check_source_all_fields "Claude rule" "$CLAUDE_RULE"

if [ "${HANDOVER_SYNC_CROSS_REPO:-0}" = "1" ]; then
  echo ""
  echo "--- 方向1b: 正本 10+7 → version-controlled cross-tool sources ---"
  check_source_all_fields "Codex payload" "$AIDD_ROOT/design/ops/payloads/codex-AGENTS-append.md"
  check_source_all_fields "Cursor payload" "$AIDD_ROOT/design/ops/payloads/cursor-aidd-delegation.mdc"
  check_source_all_fields "OpenCode payload" "$AIDD_ROOT/design/ops/payloads/opencode-AGENTS-append.md"
  check_source_all_fields "OpenCode runtime profile" "$OPENCODE_PROFILE"
  for source_entry in \
    "Codex-payload:$AIDD_ROOT/design/ops/payloads/codex-AGENTS-append.md" \
    "Cursor-payload:$AIDD_ROOT/design/ops/payloads/cursor-aidd-delegation.mdc" \
    "OpenCode-payload:$AIDD_ROOT/design/ops/payloads/opencode-AGENTS-append.md" \
    "OpenCode-profile:$OPENCODE_PROFILE"; do
    source_name="${source_entry%%:*}"
    source_path="${source_entry#*:}"
    compare_named_section "diagnostic" "## 診断プロトコル（可視化のみ）" "$source_name" "$source_path"
    compare_named_section "agent-lane" "## Git 履歴のツール帰属（可視化のみ）" "$source_name" "$source_path"
  done
  for payload_entry in \
    "Codex-payload:$AIDD_ROOT/design/ops/payloads/codex-AGENTS-append.md" \
    "Cursor-payload:$AIDD_ROOT/design/ops/payloads/cursor-aidd-delegation.mdc" \
    "OpenCode-payload:$AIDD_ROOT/design/ops/payloads/opencode-AGENTS-append.md"; do
    payload_name="${payload_entry%%:*}"
    payload_path="${payload_entry#*:}"
    compare_named_section "h5-marker" "## AI作成PR本文のH5マーカー書式" "$payload_name" "$payload_path"
  done
else
  echo "  NOTICE: HANDOVER_SYNC_CROSS_REPO=1 未指定。リポ横断の source 同期は未証明。"
fi

if [ "${HANDOVER_SYNC_DEPLOYED:-0}" = "1" ]; then
  echo ""
  echo "--- 方向1c: 正本 10+7 → home 配備先（tool=$SYNC_TOOL、source 同期と別計数） ---"
  CURSOR_CAT="$SYNC_TMP/cursor-deployed.mdc"
  if wants_tool cursor && [ -d "$CURSOR_RULES" ]; then
    find "$CURSOR_RULES" -type f -name '*.mdc' -exec cat {} + >"$CURSOR_CAT"
  fi
  if wants_tool codex; then check_source_all_fields "Codex deployed" "$CODEX_DEPLOYED"; fi
  if wants_tool cursor; then check_source_all_fields "Cursor deployed" "$CURSOR_CAT"; fi
  if wants_tool opencode; then check_source_all_fields "OpenCode deployed" "$OPENCODE_DEPLOYED"; fi

  echo ""
  echo "--- 方向1d: version-controlled payload → home 配備先 ---"
  if wants_tool codex; then
    compare_contract_field_set "codex-payload-home" "Codex payload" \
      "$AIDD_ROOT/design/ops/payloads/codex-AGENTS-append.md" "Codex home" "$CODEX_DEPLOYED"
  fi
  if wants_tool cursor; then
    compare_contract_field_set "cursor-payload-home" "Cursor payload" \
      "$AIDD_ROOT/design/ops/payloads/cursor-aidd-delegation.mdc" "Cursor home" "$CURSOR_CAT"
  fi
  if wants_tool opencode; then
    compare_contract_field_set "opencode-payload-home" "OpenCode payload" \
      "$AIDD_ROOT/design/ops/payloads/opencode-AGENTS-append.md" "OpenCode home" "$OPENCODE_DEPLOYED"
  fi
  for section_entry in \
    "h5-marker:## AI作成PR本文のH5マーカー書式" \
    "diagnostic:## 診断プロトコル（可視化のみ）" \
    "agent-lane:## Git 履歴のツール帰属（可視化のみ）"; do
    section_key="${section_entry%%:*}"
    section_heading="${section_entry#*:}"
    if wants_tool codex; then
      compare_section_pair "codex-${section_key}" "$section_heading" "Codex payload" \
        "$AIDD_ROOT/design/ops/payloads/codex-AGENTS-append.md" "Codex home" "$CODEX_DEPLOYED"
    fi
    if wants_tool cursor; then
      compare_section_pair "cursor-${section_key}" "$section_heading" "Cursor payload" \
        "$AIDD_ROOT/design/ops/payloads/cursor-aidd-delegation.mdc" "Cursor home" "$CURSOR_CAT"
    fi
    if wants_tool opencode; then
      compare_section_pair "opencode-${section_key}" "$section_heading" "OpenCode payload" \
        "$AIDD_ROOT/design/ops/payloads/opencode-AGENTS-append.md" "OpenCode home" "$OPENCODE_DEPLOYED"
    fi
  done

  if wants_tool opencode; then
    echo ""
    echo "--- 方向1e: OpenCode home 配備版 → 実 wrapper profile ---"
    compare_contract_field_set "opencode-home-profile" "OpenCode home" \
      "$OPENCODE_DEPLOYED" "OpenCode profile" "$OPENCODE_PROFILE"
    compare_section_pair "opencode-home-profile-diagnostic" "## 診断プロトコル（可視化のみ）" \
      "OpenCode home" "$OPENCODE_DEPLOYED" "OpenCode profile" "$OPENCODE_PROFILE"
    compare_section_pair "opencode-home-profile-agent-lane" "## Git 履歴のツール帰属（可視化のみ）" \
      "OpenCode home" "$OPENCODE_DEPLOYED" "OpenCode profile" "$OPENCODE_PROFILE"
  fi
else
  echo "  NOTICE: HANDOVER_SYNC_DEPLOYED=1 未指定。home 配備は未証明。"
fi

echo ""
echo "--- 方向2: 発行済み handover の委任契約欄 → 正本 ---"
if [ ! -d "$HANDOVER_DIR" ]; then
  echo "  SKIP: $HANDOVER_DIR 不在"
  SKIP=$((SKIP + 1))
else
  used="$({
    for handover_file in "$HANDOVER_DIR"/*.md; do
      [ -e "$handover_file" ] || continue
      extract_handover_fields "$handover_file"
    done
  } | sort -u)"
  if [ -z "$used" ]; then
    echo "  SKIP: 委任契約表を持つ handover が無い"
    SKIP=$((SKIP + 1))
  else
    while IFS= read -r field; do
      [ -z "$field" ] && continue
      canonical="$field"
      alias="$(canon_alias_of "$field")"
      if field_present "$canonical" "$CANON" || { [ -n "$alias" ] && field_present "$alias" "$CANON"; }; then
        echo "  PASS: handover「${field}」 → 正本定義あり"
        PASS=$((PASS + 1))
      else
        echo "  FAIL: handover「${field}」=使用あり / 正本=定義なし"
        FAIL=$((FAIL + 1))
      fi
    done <<EOF
$used
EOF
  fi
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
if [ "$PASS" -eq 0 ]; then
  echo "FAIL: 検査対象を 1 つも実測できなかった"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
