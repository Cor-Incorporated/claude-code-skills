#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/notify-agent-failure.sh
# test-agent-failure-notify.sh — propagate Agent failures to parent context
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "${GREEN}  PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "${RED}  FAIL${NC} $1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/notify-agent-failure.sh"
SETTINGS="$ROOT/settings.json"

# T9-2: この harness が誘発する台帳行は source=test（既定の real ではない）。
export AIDD_LEDGER_SOURCE=test

tmp_home=""
cleanup() {
  [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
}
trap cleanup EXIT

echo "=== Agent failure notify tests ==="

if bash -n "$HOOK" 2>/dev/null; then
  pass "T1: syntax check"
else
  fail "T1: syntax check failed"
fi

tmp_home=$(mktemp -d)
payload='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"Push branch and create PR","team_name":"team"},"error":"🚫 [BLOCK] サブエージェント/Team worker から ask 権限が必要な Git/GitHub 書き込みは実行できません。","is_interrupt":false}'
out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK")
if echo "$out" | grep -q '"hookEventName": "PostToolUseFailure"'; then
  pass "T2: returns PostToolUseFailure context"
else
  fail "T2: missing PostToolUseFailure context"
fi

if echo "$out" | grep -q 'stage: permission_gate'; then
  pass "T3: classifies permission gate failures"
else
  fail "T3: permission stage classification missing"
fi

state_file="$tmp_home/.claude/state/agent-failure-last.json"
if [[ -f "$state_file" ]]; then
  pass "T4: writes latest agent failure state"
else
  fail "T4: missing agent failure state file"
fi

if jq -e '.failure_stage == "permission_gate"' "$state_file" >/dev/null 2>&1; then
  pass "T5: state file stores failure_stage"
else
  fail "T5: state file missing failure_stage"
fi

payload='{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"},"error":"context budget exceeded after 6 source reads","is_interrupt":false}'
out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK")
if echo "$out" | grep -q 'stage: context_budget'; then
  pass "T6: classifies context budget failures"
else
  fail "T6: context budget classification missing"
fi

payload='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"error":"Aborted","is_interrupt":true}'
if out=$(echo "$payload" | HOME="$tmp_home" bash "$HOOK" 2>&1); then
  if [[ -z "$out" ]]; then
    pass "T7: interrupted failures are ignored"
  else
    fail "T7: expected no output for interrupt"
  fi
else
  fail "T7: interrupt should not fail"
fi

if grep -q 'notify-agent-failure.sh' "$SETTINGS"; then
  pass "T8: settings.json registers Agent failure hook"
else
  fail "T8: settings.json missing Agent failure hook"
fi

echo ""
echo "=== F3 片側変異: 判定を 1 つずつ外すと対応するケースだけが反転する ==="
# T2-T7 は「分類が出た / 出なかった」を見ているが、それだけでは
# **その分類を hook のどの判定が作ったか**を証明していない。
# 変異体はこのテスト自身が作り、同じ実行の中で走らせる。外から差し込む形にしない
# （CI がその赤を一度も見ない。tests/test-issue-263-multi-repo-ctx.sh 冒頭の実測を参照）。

MUT_DIR="$tmp_home/mut-hooks"
mkdir -p "$MUT_DIR"
# 変異体は lib/aidd-ledger.sh を BASH_SOURCE 相対で source する。lib を伴わせないと
# 落ちてしまい、「差が出た」ではなく「動かなかった」になる。
if cp -R "$ROOT/hooks/lib" "$MUT_DIR/lib"; then
  pass "M0: 変異体の依存 (hooks/lib) を複製できた"
else
  fail "M0: hooks/lib を複製できない — 変異体は正しく走らない"
fi

# mutate <出力先> <old> <new> — 対象がちょうど 1 件でなければ反証不能として落とす
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

PERM_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"Push branch and create PR","team_name":"team"},"error":"🚫 [BLOCK] サブエージェント/Team worker から ask 権限が必要な Git/GitHub 書き込みは実行できません。","is_interrupt":false}'
INTERRUPT_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"error":"Aborted","is_interrupt":true}'

# --- M1: permission_gate の分類分岐を落とす ---
MUT1="$MUT_DIR/m1.sh"
if mutate "$MUT1" "if echo \"\$error_msg\" | grep -qiE 'permission|ask 権限|ask permission|Git/GitHub 書き込み|^\\s*🚫 \\[BLOCK\\]'; then" \
                  'if false; then  # 変異: permission_gate を分類しない'; then
  pass "M1: 変異体を生成できた（分類分岐がちょうど 1 件）"

  # 統制: 変異と無関係な出力枠は変異体でも出続けなければならない。
  # ここが崩れていたら変異体は「壊れた」のであって「違う判定を出した」のではない。
  mut_out=$(echo "$PERM_PAYLOAD" | HOME="$tmp_home" bash "$MUT1" 2>/dev/null || true)
  if echo "$mut_out" | grep -q '"hookEventName": "PostToolUseFailure"'; then
    pass "M1 統制: 変異体も PostToolUseFailure を返す = 変異は局所的"
  else
    fail "M1 統制: 変異体が壊れている（この節の red は変異の証明にならない）"
  fi

  if echo "$mut_out" | grep -q 'stage: tool_execution' && ! echo "$mut_out" | grep -q 'stage: permission_gate'; then
    pass "M1: 変異体は permission_gate を出さず既定へ落ちる = T3 は分類分岐が作っていた"
  else
    fail "M1: 変異体でも permission_gate が出る = T3 は別経路が出している"
  fi
else
  fail "M1: 変異体を作れなかった — この節は反証不能"
fi

# --- M2: is_interrupt の早期 return を落とす ---
MUT2="$MUT_DIR/m2.sh"
if mutate "$MUT2" '[[ "$is_interrupt" == "true" ]] && exit 0' \
                  ':  # 変異: 中断でも通知を出す'; then
  pass "M2: 変異体を生成できた（早期 return がちょうど 1 件）"

  mut_out=$(echo "$INTERRUPT_PAYLOAD" | HOME="$tmp_home" bash "$MUT2" 2>/dev/null || true)
  if [[ -n "$mut_out" ]]; then
    pass "M2: 変異体は中断でも通知を出す = T7 は早期 return が作っていた"
  else
    fail "M2: 変異体でも無言 = T7 は別条件が出している"
  fi
else
  fail "M2: 変異体を作れなかった — この節は反証不能"
fi

# --- M3: 状態ファイル書き出しを落とす（T4/T5 の担保先） ---
MUT3="$MUT_DIR/m3.sh"
if mutate "$MUT3" "printf '%s\\n' \"\$summary\" > \"\$STATE_FILE\"" \
                  ':  # 変異: 状態ファイルを書かない'; then
  pass "M3: 変異体を生成できた（状態書き出しがちょうど 1 件）"

  mut_home="$tmp_home/m3home"
  mkdir -p "$mut_home"
  mut_out=$(echo "$PERM_PAYLOAD" | HOME="$mut_home" bash "$MUT3" 2>/dev/null || true)
  # 統制を先に置く。落ちた変異体でも状態ファイルは「無い」ので、
  # 不在だけを見ると壊れた変異体が PASS になる（不在は成功の証拠にならない）。
  if echo "$mut_out" | grep -q '"hookEventName": "PostToolUseFailure"'; then
    pass "M3 統制: 変異体は最後まで走っている（通知は出る）= 変異は局所的"
  else
    fail "M3 統制: 変異体が途中で落ちている（この節の不在は変異の証明にならない）"
  fi
  if [[ ! -f "$mut_home/.claude/state/agent-failure-last.json" ]]; then
    pass "M3: 変異体は状態ファイルを残さない = T4/T5 は書き出しが作っていた"
  else
    fail "M3: 変異体でも状態ファイルがある = T4/T5 は別経路が作っている"
  fi
else
  fail "M3: 変異体を作れなかった — この節は反証不能"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
