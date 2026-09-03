#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/validate-no-local-hooks.sh
# =============================================================================
# validate-no-local-hooks.sh の反証テスト（SessionStart / ハードブロック）
# =============================================================================
# 何を守っている装置か:
#   ~/.claude/settings.local.json に "hooks" があると、グローバル settings.json
#   の hooks を**丸ごと上書き**する。PR merge gate も push guard も無効になる。
#   この装置はセッション開始時にそれを検出して exit 2 でセッションを止める。
#
# なぜこのファイルが今まで無かったか（本テスト新設の理由）:
#   2026-09-03 実測。settings.json に登録された検査器 23 本のうち、
#   validate-no-local-hooks.sh は**テストファイル自体が存在しなかった**。
#   ハードブロック 3 本の 1 本が、判定を一度も実行されないまま登録されていた。
#
# 反証軸 F3（片側変異）:
#   判定を 1 つずつ外した変異体をこのテスト自身が作り、同じ実行の中で走らせる。
#   変異体で対応するケースだけが反転すれば、上の緑はその判定が作っている。
#   外から HOOK_DIR で壊れた版を差し込む形にはしない — CI がその赤を一度も
#   見ないうえ、参照先（origin/develop）が動いて自分で無効化されるため
#   （tests/test-issue-263-multi-repo-ctx.sh 冒頭の実測を参照）。
#
# 判定内容は一切変更しない。テストのための迂回口も新設しない。
# HOME はサンドボックスへ向け、実 settings.local.json と実台帳には触れない。
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/validate-no-local-hooks.sh"

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

# run_hook <hook_path> <settings.local.json の中身 | __ABSENT__>
# 隔離した HOME で実行し、exit code を LAST_RC、台帳を LAST_LEDGER へ入れる。
LAST_RC=0
LAST_LEDGER=""
run_hook() {
  local hook="$1" content="$2"
  local home="$TMP/home.$RANDOM.$$"
  mkdir -p "$home/.claude"
  if [ "$content" != "__ABSENT__" ]; then
    printf '%s' "$content" > "$home/.claude/settings.local.json"
  fi
  LAST_RC=0
  HOME="$home" bash "$hook" >/dev/null 2>&1 || LAST_RC=$?
  LAST_LEDGER="$(cat "$home/.claude/hooks/ledger/guard-ledger.jsonl" 2>/dev/null || true)"
}

echo "=== F1 真理値表: settings.local.json の状態 × 判定 ==="

run_hook "$HOOK" '__ABSENT__'
[ "$LAST_RC" -eq 0 ] \
  && ok "ファイルが無い → exit 0（通す）" \
  || bad "ファイルが無いのに止めた（exit ${LAST_RC}）" "誤検知はセッションを開けなくする"

run_hook "$HOOK" '{"permissions":{"allow":["Bash"]}}'
[ "$LAST_RC" -eq 0 ] \
  && ok "hooks 以外のキーだけ → exit 0（通す）" \
  || bad "hooks が無いのに止めた（exit ${LAST_RC}）" "$LAST_LEDGER"

run_hook "$HOOK" '{}'
[ "$LAST_RC" -eq 0 ] \
  && ok "空オブジェクト → exit 0（通す）" \
  || bad "空オブジェクトで止めた（exit ${LAST_RC}）" "$LAST_LEDGER"

run_hook "$HOOK" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}'
[ "$LAST_RC" -eq 2 ] \
  && ok "hooks あり → exit 2（ブロック）" \
  || bad "hooks があるのに通した（exit ${LAST_RC}）" "グローバル hooks 全滅を見逃す = 守るべきものを守っていない"

# hooks キーが空でも「上書きは起きる」ので block でなければならない。
run_hook "$HOOK" '{"hooks":{}}'
[ "$LAST_RC" -eq 2 ] \
  && ok "hooks が空オブジェクトでも exit 2（上書きは起きる）" \
  || bad "空 hooks を通した（exit ${LAST_RC}）" "jq has(\"hooks\") は空でも true"

echo ""
echo "=== H6 台帳: 発火が guard-ledger.jsonl へ届く ==="
run_hook "$HOOK" '{"hooks":{"SessionStart":[]}}'
if printf '%s' "$LAST_LEDGER" | grep -q '"rule":"local-hooks-present"'; then
  ok "block が台帳へ届く（rule=local-hooks-present）"
else
  bad "台帳に届かない" "ledger=${LAST_LEDGER:-<empty>}"
fi
if printf '%s' "$LAST_LEDGER" | grep -q '"source":"test"'; then
  ok "台帳行が source=test（実台帳の real 行を汚さない）"
else
  bad "source=test になっていない" "ledger=${LAST_LEDGER:-<empty>}"
fi

echo ""
echo "=== F3 片側変異: 判定を外すと block ケースだけが素通しへ戻る ==="

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

# --- M1: hooks 検出の比較を落とす（判定そのもの） ---
M1="$MUT_DIR/m1.sh"
if mutate "$M1" '  if [[ "$HAS_HOOKS" == "true" ]]; then' \
                '  if false; then  # 変異: hooks を検出しない'; then
  ok "M1 変異体を生成できた（比較がちょうど 1 件）"

  # 統制: 変異と無関係なケースは変異体でも同じ答えでなければならない。
  # ここが崩れていたら変異体は「壊れた」のであって「違う判定を出した」のではない。
  run_hook "$M1" '{"permissions":{"allow":["Bash"]}}'
  [ "$LAST_RC" -eq 0 ] \
    && ok "M1 統制: hooks 無しは変異体でも exit 0 = 変異は局所的" \
    || bad "M1 変異体が統制ケースで壊れている（exit ${LAST_RC}）" "この節の red は変異の証明にならない"

  run_hook "$M1" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}'
  if [ "$LAST_RC" -eq 0 ]; then
    ok "M1 変異体は hooks あり を素通しする = 比較が結論を作っていた"
  else
    bad "M1 変異体でも止めた（exit ${LAST_RC}）" "上の block は別条件が出している"
  fi
else
  bad "M1 変異体を作れなかった — この節は反証不能" "mutation target missing in $HOOK"
fi

# --- M2: 台帳追記だけを落とす（H6 配線。block 権限はそのまま） ---
M2="$MUT_DIR/m2.sh"
if mutate "$M2" '    aidd_ledger_append "validate-no-local-hooks" "block" "deny" "settings.local.json hooks" "local-hooks-present"' \
                '    :  # 変異: 台帳へ書かない'; then
  ok "M2 変異体を生成できた（台帳呼び出しがちょうど 1 件）"

  run_hook "$M2" '{"hooks":{"SessionStart":[]}}'
  if [ "$LAST_RC" -eq 2 ] && ! printf '%s' "$LAST_LEDGER" | grep -q 'local-hooks-present'; then
    ok "M2 変異体は block したまま台帳行を落とす = 台帳節は台帳配線を測っていた"
  else
    bad "M2 変異体の挙動が期待と違う（exit ${LAST_RC}）" \
        "ledger=${LAST_LEDGER:-<empty>} — 台帳節が block 権限と分離できていない"
  fi
else
  bad "M2 変異体を作れなかった — この節は反証不能" "ledger call not found in $HOOK"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
