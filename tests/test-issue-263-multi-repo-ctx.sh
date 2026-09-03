#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/git-push-guard.sh
# =============================================================================
# Regression test: multi-repository `git -C` context resolution (Issue #263)
# =============================================================================
# Pre-existing gap: git-push-guard.sh resolved its git context dir with a single
# `re.search` for the FIRST `git -C <dir>` anywhere in the command, without
# pairing it to the invocation that actually pushes. In a chained command naming
# two repos, the implicit-branch force-push check (Issue #28) therefore read the
# wrong repo's HEAD:
#
#   git -C <feature-repo> status && git -C <protected-repo> push --force
#       -> ctx = feature repo -> NOT protected -> force push ALLOWED (exit 0)
#
# Both directions were wrong: the above is a fail-open BYPASS, and the mirror
# case (protected repo named first, feature repo pushed) was a FALSE BLOCK.
#
# Falsifiability: the "F3 片側変異" section at the bottom builds the UNFIXED hook
# ITSELF (in this same run) and asserts the BYPASS / FALSE BLOCK cases flip.
#
# It used to say: reconstruct the unfixed hook by hand with
#   git show origin/develop:hooks/git-push-guard.sh > /tmp/unfixed/...
#   HOOK_DIR=/tmp/unfixed bash tests/test-issue-263-multi-repo-ctx.sh
# That recipe is dead and was never run by CI. Two independent reasons:
#   1. CI runs `bash tests/test-*.sh` with no HOOK_DIR (.github/workflows/ci.yml),
#      so only the green side ever executed. The guard could rot and stay green.
#   2. `origin/develop` is a MOVING ref. Once the #263 fix landed there, the
#      recipe started producing the FIXED hook. 2026-09-03 実測: it yields
#      "15 passed, 0 failed" — the red is gone, so the recipe proves nothing.
# 陰性テストが「ある」ことと「走る」ことは別である。変異体はテストが自分で作る。
#
# The hook is fed JSON on stdin via jq; no git push is ever executed, so the
# runner's own PreToolUse guards are never triggered. The fixture repos are
# real (the check runs `git rev-parse --abbrev-ref HEAD` against them) and are
# created under mktemp, then removed on exit.
#
# Usage:
#   bash tests/test-issue-263-multi-repo-ctx.sh              # source hooks
#   HOOK_DIR=~/.claude/hooks bash tests/test-issue-263-...   # deployed hooks
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="${HOOK_DIR:-$SCRIPT_DIR/../hooks}"
PUSH_GUARD="$HOOK_DIR/git-push-guard.sh"
PASS=0
FAIL=0

# T9-2: rows this harness provokes are source=test, never source=real.
# hooks/lib/aidd-ledger.sh のヘッダが「テストハーネスが hook を叩く箇所で
# export すること」と要求している。判定は一切変えない（迂回口ではない）。
export AIDD_LEDGER_SOURCE=test

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# FEAT: on a feature branch (not protected).  PROT: on develop (protected).
FEAT="$TMP/feature-repo"
PROT="$TMP/protected-repo"
mkdir -p "$FEAT" "$PROT"
git -C "$FEAT" init -q
git -C "$FEAT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$FEAT" checkout -q -b feat/harmless
git -C "$PROT" init -q
git -C "$PROT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$PROT" checkout -q -b develop

# guard_exit <hook_path> <command>  -> echoes the hook's exit code
guard_exit() {
  local hook="$1" cmd="$2" json rc=0
  json=$(jq -n --arg cmd "$cmd" '{tool_input:{command:$cmd}}')
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# test_case <name> <expected_exit> <command>
test_case() {
  local name="$1" expected_exit="$2" cmd="$3"
  local actual_exit
  actual_exit=$(guard_exit "$PUSH_GUARD" "$cmd")
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS: $name (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected=$expected_exit actual=$actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "    $2"; FAIL=$((FAIL + 1)); }

echo "=== HOOK_DIR: $HOOK_DIR ==="
echo "  feature repo on: $(git -C "$FEAT" rev-parse --abbrev-ref HEAD)"
echo "  protected repo on: $(git -C "$PROT" rev-parse --abbrev-ref HEAD)"
echo ""

echo "--- Controls: single repo, implicit branch (must hold pre- and post-fix) ---"
test_case "single protected repo, implicit force"   2 "git -C $PROT push --force"
test_case "single feature repo, implicit force"     0 "git -C $FEAT push --force"

echo "--- BYPASS: pushing invocation's repo is protected, named second ---"
test_case "feature -C first, protected pushes"      2 "git -C $FEAT status && git -C $PROT push --force"
test_case "feature -C first, force-with-lease"      2 "git -C $FEAT log -1 && git -C $PROT push --force-with-lease"
test_case "second push hidden behind benign push"   2 "git -C $FEAT push --force && git -C $PROT push --force"
test_case "protected push after semicolon chain"    2 "git -C $FEAT status ; git -C $PROT push -f"

echo "--- FALSE BLOCK: pushing invocation's repo is a feature branch ---"
test_case "protected -C first, feature pushes"      0 "git -C $PROT status && git -C $FEAT push --force"
test_case "protected -C first, feature -f"          0 "git -C $PROT log -1 && git -C $FEAT push -f"

echo "--- cd fallback must survive (no -C on the pushing invocation) ---"
test_case "cd protected && implicit force"          2 "cd $PROT && git push --force"
test_case "cd feature && implicit force"            0 "cd $FEAT && git push --force"
test_case "cd feature, -C protected pushes"         2 "cd $FEAT && git -C $PROT push --force"
test_case "cd protected, -C feature pushes"         0 "cd $PROT && git -C $FEAT push --force"

echo "--- A quoted 'git -C' must not shadow the real context ---"
test_case "quoted bogus -C, cd protected"           2 "cd $PROT && gh issue create --title \"git -C /nonexistent push\" && git push --force"

echo "--- Explicit refspecs are unaffected by ctx resolution ---"
test_case "explicit protected ref, feature ctx"     2 "git -C $FEAT status && git push --force origin develop"
test_case "explicit feature ref, protected ctx"     0 "git -C $PROT status && git push --force origin feat/x"

echo ""
echo "=== F3 片側変異: 修正を外すと BYPASS / FALSE BLOCK だけが元の誤りへ戻る ==="
# 変異体はテストが自分で作る。外から HOOK_DIR で差し込む形にしない
# （走らない・参照先が動いて腐る。ファイル冒頭の注記を参照）。
#
# 変異は #263 の修正そのもの 1 点だけを剥がす:
#   修正後 = push する各セグメントごとに `git -C` を解決して全部出す
#   変異体 = コマンド全体で最初の `git -C` を 1 回だけ解決する（修正前の形）
#
# 変異体は hooks/lib/aidd-ledger.sh を BASH_SOURCE 相対で source する。
# lib を伴わせずに置くと exit 127 で落ち、「差が出た」ではなく「動かなかった」に
# なる。落ちた変異体は変異の証明にならないので、hooks ツリーごと複製する。
MUT_HOOKS="$TMP/mut-hooks"
mkdir -p "$MUT_HOOKS"
# lib のコピー失敗を握り潰さない。黙って落とすと変異体は exit 127 になり、
# 「修正を外したから反転した」ではなく「動かなかったから反転した」になる。
if cp -R "$HOOK_DIR/lib" "$MUT_HOOKS/lib"; then
  ok "変異体の依存 (hooks/lib) を複製できた"
else
  bad "hooks/lib を複製できない — 変異体は exit 127 で落ちる" "src=$HOOK_DIR/lib"
fi
MUT="$MUT_HOOKS/git-push-guard.sh"

if python3 - "$PUSH_GUARD" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = """seen, out = set(), []
for seg in re.split(r'&&|\\|\\||[;\\n|]', cmd):
    if not re.search(r'\\bgit\\b.*\\bpush\\b', seg):
        continue
    d = _resolve(re.search(r'git\\s+-C\\s+' + pat_val, seg)) or lead_cd
    if d not in seen:
        seen.add(d)
        out.append(d)
print("\\n".join(out) if out else lead_cd)"""
assert t.count(old) == 1, f"変異対象が {t.count(old)} 件（1 件でなければ反証不能）"
new = """# 変異: セグメント単位の解決を捨て、コマンド全体の最初の -C を 1 回だけ使う
print(_resolve(re.search(r'git\\s+-C\\s+' + pat_val, cmd)) or lead_cd)"""
pathlib.Path(dst).write_text(t.replace(old, new, 1), encoding="utf-8")
PY
then
  ok "変異体を生成できた（変異対象がちょうど 1 件）"
else
  bad "変異体を作れなかった — この節は反証不能" "mutation target missing in $PUSH_GUARD"
fi

# 変異体が「動かない」のではなく「違う判定を出す」ことを先に確かめる。
# 単一 repo の統制ケースは修正と無関係なので、変異体でも同じ答えでなければならない。
if [ -f "$MUT" ]; then
  mut_rc=$(guard_exit "$MUT" "git -C $PROT push --force")
  if [ "$mut_rc" -eq 2 ]; then
    ok "変異体は統制ケース（単一 protected repo）で block のまま = 変異は局所的"
  else
    bad "変異体が統制ケースで壊れている（exit ${mut_rc}、期待 2）" \
        "変異体が実行できていない。この節の red は変異の証明にならない"
  fi

  # mut_case <name> <expected_on_mutant> <command>
  # 期待値は「修正前の誤った答え」。変異体がこれを返せば、その判定は
  # #263 の修正が作っていたことになる（= 上の緑は結論を作っている）。
  mut_case() {
    local name="$1" want="$2" cmd="$3" got
    got=$(guard_exit "$MUT" "$cmd")
    if [ "$got" -eq "$want" ]; then
      ok "変異 $name → 元の誤り exit $got へ戻った"
    else
      bad "変異 $name が反転しない（exit ${got}、期待 ${want}）" \
          "この行の緑は #263 の修正が作っていない — 別条件が出している"
    fi
  }

  echo "--- BYPASS 4 件: block(2) → 素通し(0) へ戻る ---"
  mut_case "feature -C first, protected pushes"   0 "git -C $FEAT status && git -C $PROT push --force"
  mut_case "feature -C first, force-with-lease"   0 "git -C $FEAT log -1 && git -C $PROT push --force-with-lease"
  mut_case "second push hidden behind benign"     0 "git -C $FEAT push --force && git -C $PROT push --force"
  mut_case "protected push after semicolon chain" 0 "git -C $FEAT status ; git -C $PROT push -f"

  echo "--- FALSE BLOCK 2 件: allow(0) → 誤 block(2) へ戻る ---"
  mut_case "protected -C first, feature pushes"   2 "git -C $PROT status && git -C $FEAT push --force"
  mut_case "protected -C first, feature -f"       2 "git -C $PROT log -1 && git -C $FEAT push -f"

  echo "--- 修正と無関係な統制は変異体でも変わらない ---"
  mut_case "cd protected && implicit force"       2 "cd $PROT && git push --force"
  mut_case "cd feature && implicit force"         0 "cd $FEAT && git push --force"
  mut_case "explicit protected ref, feature ctx"  2 "git -C $FEAT status && git push --force origin develop"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
