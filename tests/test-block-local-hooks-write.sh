#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/block-local-hooks-write.sh
# =============================================================================
# block-local-hooks-write.sh の反証テスト（PreToolUse Edit|Write / ハードブロック）
# =============================================================================
# 何を守っている装置か:
#   settings.local.json へ "hooks" を**書こうとした時点で**止める。
#   書けてしまうとグローバル settings.json の hooks が丸ごと上書きされ、
#   push guard も merge gate も無効になる。
#   validate-no-local-hooks.sh が「既に書かれている」を検出するのに対し、
#   こちらは「これから書く」を止める（事前 / 事後の対）。
#
# なぜこのファイルが今まで無かったか（本テスト新設の理由）:
#   2026-09-03 実測。監督の台帳では本装置は「テストあり」と数えられていたが、
#   根拠にされていた tests/test-t92-ledger-source.sh は
#   hooks/lib/aidd-ledger.sh の source 列を検査しているだけで、
#   "block-local-hooks-write.sh" を**文字列引数として渡しているにすぎない**。
#   hooks/block-local-hooks-write.sh を一度も実行しない。
#   したがって block 判定は実測上まったく検査されていなかった。
#
# 反証軸 F3（片側変異）: 変異体はこのテスト自身が作り、同じ実行の中で走らせる。
# 判定内容は一切変更しない。テストのための迂回口も新設しない。
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/block-local-hooks-write.sh"

# T9-2: この harness が誘発する台帳行は source=test（既定の real ではない）。
export AIDD_LEDGER_SOURCE=test

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "    $2"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq が無い環境では本装置は判定に到達しない（hook 側の設計）"
  exit 0
}

# run_hook <hook_path> <stdin JSON>
# 隔離した HOME で実行し、exit code を LAST_RC、台帳を LAST_LEDGER へ入れる。
LAST_RC=0
LAST_LEDGER=""
run_hook() {
  local hook="$1" payload="$2"
  local home="$TMP/home.$RANDOM.$$"
  mkdir -p "$home"
  LAST_RC=0
  printf '%s' "$payload" | HOME="$home" bash "$hook" >/dev/null 2>&1 || LAST_RC=$?
  LAST_LEDGER="$(cat "$home/.claude/hooks/ledger/guard-ledger.jsonl" 2>/dev/null || true)"
}

# payload <file_path> <content_key> <content>
payload() {
  jq -nc --arg p "$1" --arg k "$2" --arg c "$3" '{tool_input:{file_path:$p}} | .tool_input[$k]=$c'
}

LOCAL="$HOME/.claude/settings.local.json"
HOOKS_CONTENT='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}'
PLAIN_CONTENT='{"permissions":{"allow":["Bash"]}}'

echo "=== F1 真理値表: 対象ファイル × 中身 × ツール種別 ==="

run_hook "$HOOK" "$(payload "$LOCAL" content "$HOOKS_CONTENT")"
[ "$LAST_RC" -eq 2 ] \
  && ok "settings.local.json へ hooks を Write → exit 2（ブロック）" \
  || bad "hooks の書き込みを通した（exit ${LAST_RC}）" "グローバル hooks 全滅を許す = 守るべきものを守っていない"

run_hook "$HOOK" "$(payload "$LOCAL" new_string "$HOOKS_CONTENT")"
[ "$LAST_RC" -eq 2 ] \
  && ok "settings.local.json へ hooks を Edit(new_string) → exit 2" \
  || bad "Edit 経路を通した（exit ${LAST_RC}）" "Write だけ塞いでも Edit で迂回できてしまう"

run_hook "$HOOK" "$(payload "$LOCAL" content "$PLAIN_CONTENT")"
[ "$LAST_RC" -eq 0 ] \
  && ok "settings.local.json でも hooks を含まなければ exit 0（通す）" \
  || bad "hooks の無い local 設定を止めた（exit ${LAST_RC}）" "誤検知は permissions 編集を塞ぐ"

run_hook "$HOOK" "$(payload "$HOME/.claude/settings.json" content "$HOOKS_CONTENT")"
[ "$LAST_RC" -eq 0 ] \
  && ok "グローバル settings.json への hooks は exit 0（そこが正しい置き場）" \
  || bad "正規の置き場を止めた（exit ${LAST_RC}）" "hooks は settings.json に書くのが正しい"

run_hook "$HOOK" "$(payload "$TMP/notes.md" content "$HOOKS_CONTENT")"
[ "$LAST_RC" -eq 0 ] \
  && ok "無関係なファイルに \"hooks\": が現れても exit 0（引用は対象外）" \
  || bad "無関係ファイルを止めた（exit ${LAST_RC}）" "表面形一致 — 出現を実行として扱っている"

run_hook "$HOOK" '{"tool_input":{}}'
[ "$LAST_RC" -eq 0 ] \
  && ok "file_path が無い入力 → exit 0" \
  || bad "file_path 無しで止めた（exit ${LAST_RC}）" "$LAST_LEDGER"

run_hook "$HOOK" ''
[ "$LAST_RC" -eq 0 ] \
  && ok "空の stdin → exit 0" \
  || bad "空入力で止めた（exit ${LAST_RC}）" "$LAST_LEDGER"

echo ""
echo "=== H6 台帳: 発火が guard-ledger.jsonl へ届く ==="
run_hook "$HOOK" "$(payload "$LOCAL" content "$HOOKS_CONTENT")"
if printf '%s' "$LAST_LEDGER" | grep -q '"rule":"local-hooks-write"'; then
  ok "block が台帳へ届く（rule=local-hooks-write）"
else
  bad "台帳に届かない" "ledger=${LAST_LEDGER:-<empty>}"
fi
if printf '%s' "$LAST_LEDGER" | grep -q '"source":"test"'; then
  ok "台帳行が source=test（実台帳の real 行を汚さない）"
else
  bad "source=test になっていない" "ledger=${LAST_LEDGER:-<empty>}"
fi

echo ""
echo "=== F3 片側変異: 判定を 1 つずつ外すと対応するケースだけが反転する ==="

# 変異体は hooks/ と同じレイアウトへ置く。lib/aidd-ledger.sh を BASH_SOURCE 相対で
# source するため、lib を伴わせないと exit 127 で落ちる。落ちた変異体は
# 「差が出た」ではなく「動かなかった」であり、変異の証明にならない。
MUT_DIR="$TMP/mut-hooks"
mkdir -p "$MUT_DIR"
if cp -R "$ROOT/hooks/lib" "$MUT_DIR/lib"; then
  ok "変異体の依存 (hooks/lib) を複製できた"
else
  bad "hooks/lib を複製できない — 変異体は exit 127 で落ちる" "src=$ROOT/hooks/lib"
fi

# mutate <出力先> <old> <new>  — 対象がちょうど 1 件でなければ反証不能として落とす
mutate() {
  local dst="$1" old="$2" new="$3"
  python3 - "$HOOK" "$dst" "$old" "$new" <<'PY'
import pathlib, sys
src, dst, old, new = sys.argv[1:5]
t = pathlib.Path(src).read_text(encoding="utf-8")
n = t.count(old)
if n != 1:
    print(f"変異対象が {n} 件（1 件でなければ反証不能）: {old!r}", file=sys.stderr)
    raise SystemExit(1)
pathlib.Path(dst).write_text(t.replace(old, new, 1), encoding="utf-8")
PY
}

# --- M1: 中身の hooks 検出を落とす（判定そのもの） ---
M1="$MUT_DIR/m1.sh"
if mutate "$M1" 'if echo "$CONTENT" | grep -qE '"'"'"hooks"\s*:'"'"'; then' \
                'if false; then  # 変異: 中身の hooks を検出しない'; then
  ok "M1 変異体を生成できた（中身判定がちょうど 1 件）"

  run_hook "$M1" "$(payload "$LOCAL" content "$PLAIN_CONTENT")"
  [ "$LAST_RC" -eq 0 ] \
    && ok "M1 統制: hooks 無しは変異体でも exit 0 = 変異は局所的" \
    || bad "M1 変異体が統制ケースで壊れている（exit ${LAST_RC}）" "この節の red は変異の証明にならない"

  run_hook "$M1" "$(payload "$LOCAL" content "$HOOKS_CONTENT")"
  if [ "$LAST_RC" -eq 0 ]; then
    ok "M1 変異体は hooks の書き込みを素通しする = 中身判定が結論を作っていた"
  else
    bad "M1 変異体でも止めた（exit ${LAST_RC}）" "上の block は別条件が出している"
  fi
else
  bad "M1 変異体を作れなかった — この節は反証不能" "content check not found in $HOOK"
fi

# --- M2: 対象ファイルの絞り込みを落とす（誤検知側。片側だけ壊す） ---
M2="$MUT_DIR/m2.sh"
if mutate "$M2" 'if [[ "$FILE_PATH" != *"settings.local.json" ]]; then' \
                'if false; then  # 変異: 対象ファイルを絞らない'; then
  ok "M2 変異体を生成できた（対象絞り込みがちょうど 1 件）"

  run_hook "$M2" "$(payload "$LOCAL" content "$HOOKS_CONTENT")"
  [ "$LAST_RC" -eq 2 ] \
    && ok "M2 統制: 本来の対象は変異体でも exit 2 = 変異は局所的" \
    || bad "M2 変異体が統制ケースで壊れている（exit ${LAST_RC}）" "この節の red は変異の証明にならない"

  run_hook "$M2" "$(payload "$TMP/notes.md" content "$HOOKS_CONTENT")"
  if [ "$LAST_RC" -eq 2 ]; then
    ok "M2 変異体は無関係ファイルを誤 block する = 絞り込みが誤検知を止めていた"
  else
    bad "M2 変異体でも通した（exit ${LAST_RC}）" "上の allow は絞り込みが作っていない"
  fi
else
  bad "M2 変異体を作れなかった — この節は反証不能" "path scope not found in $HOOK"
fi

# --- M3: 台帳追記だけを落とす（H6 配線。block 権限はそのまま） ---
M3="$MUT_DIR/m3.sh"
if mutate "$M3" '    aidd_ledger_append "block-local-hooks-write" "block" "deny" "${FILE_PATH:-}" "local-hooks-write"' \
                '    :  # 変異: 台帳へ書かない'; then
  ok "M3 変異体を生成できた（台帳呼び出しがちょうど 1 件）"

  run_hook "$M3" "$(payload "$LOCAL" content "$HOOKS_CONTENT")"
  if [ "$LAST_RC" -eq 2 ] && ! printf '%s' "$LAST_LEDGER" | grep -q 'local-hooks-write'; then
    ok "M3 変異体は block したまま台帳行を落とす = 台帳節は台帳配線を測っていた"
  else
    bad "M3 変異体の挙動が期待と違う（exit ${LAST_RC}）" \
        "ledger=${LAST_LEDGER:-<empty>} — 台帳節が block 権限と分離できていない"
  fi
else
  bad "M3 変異体を作れなかった — この節は反証不能" "ledger call not found in $HOOK"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
