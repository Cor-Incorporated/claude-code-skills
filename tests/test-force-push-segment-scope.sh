#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/protect-branches.sh
# NEGATIVE-TEST-FOR: hooks/git-push-guard.sh
#
# force-push 規則の判定範囲をセグメントに固定する（claude-code-skills#365）。
#
# 発端（2026-09-05、同日 3 回運用者を止めた）:
#   protect-branches.sh Check 0b は `is_force_push` と `mentions_protected_ref` を
#   コマンド文字列**全体**に当てていた。git-push-guard.sh §1 も同じ形だった。
#
#     pkill -f 'pattern' && gh pr create --base develop ...   → `-f` + `develop` で block
#     git push origin feat/x && pkill -f foo                  → develop 上で暗黙 force と誤読
#
#   #380 が Check 1/2（削除）をセグメント化したとき、force 規則だけ行全体のまま残っていた。
#   tests/test-refspec-force-scope.sh（Check 0a2）と同じ欠陥クラスの 3 例目。
#
# 軸（test-refspec-force-scope.sh / test-delete-branch-segment-scope.sh と同じ）:
#   F1  陽性対照 — 真の force push（同一セグメント・プロセス置換・連鎖）は block のまま
#   F2  陰性対照 — force フラグと保護名が**別セグメント**にあるだけなら allow
#   F3  順序対称 — 同じ 2 セグメントは順序を入れ替えても結論が変わらない
#   F4  片側変異 — セグメント化を外す（全体照合へ戻す）と F2 が再び block する
#
# 両 hook を同じ入力で回す（片方だけ変えない）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB="$SCRIPT_DIR/../hooks/protect-branches.sh"
PG="$SCRIPT_DIR/../hooks/git-push-guard.sh"
CX="$SCRIPT_DIR/../hooks/codex/protect-branches-codex.sh"
PASS=0; FAIL=0
export AIDD_LEDGER_SOURCE=test

# 暗黙ブランチのフォールバックは current branch を読む。develop 上で測るのが
# 事故入力の再現条件（運用者は develop 上で止められた）。fixture で明示的に develop に立つ。
FIX=$(mktemp -d)
git init -q "$FIX"
git -C "$FIX" symbolic-ref HEAD refs/heads/develop
git -C "$FIX" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
# Codex guard は #387 まで develop 上で**あらゆる push** を current で deny していた。
# #387（push_destination の移植）で直したので、Codex 行も develop fixture で回す
# （3 ガードが同じ入力・同じブランチで同じ結論を出すことが対の検査）。
trap 'rm -rf "$FIX"' EXIT

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
# run_case <hook> <label> <name> <expect> <cmd>
# Claude Code 側 2 本は exit code で、Codex 側は permissionDecision=deny で判定する。
run_case() {
  local hook="$1" label="$2" name="$3" expect="$4" cmd="$5" dir="${6:-}" rc=0 out="" actual
  if [ "$label" = "codex" ]; then
    dir="${dir:-$FIX}"
    out=$(printf '{"tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
      | (cd "$dir" && CODEX_GUARD_LEDGER="$dir/codex-ledger.jsonl" bash "$hook" 2>/dev/null) || true)
    if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then actual=block; else actual=allow; fi
  else
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
      | (cd "$FIX" && bash "$hook" >/dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then actual=block; else actual=allow; fi
  fi
  if [ "$actual" = "$expect" ]; then
    echo "  PASS: [$label] $name ($actual)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [$label] $name expected=$expect actual=$actual cmd=$cmd"; FAIL=$((FAIL + 1))
  fi
}
both() { run_case "$PB" protect-branches "$@"; run_case "$PG" git-push-guard "$@"; run_case "$CX" codex "$@"; }

echo "=== 測定ブランチ: 3 ガードとも $(git -C "$FIX" rev-parse --abbrev-ref HEAD)（保護） ==="

echo ""
echo "=== F1 陽性対照: 真の force push は block のまま ==="
both "同一セグメント --force main"            block 'git push --force origin main'
both "同一セグメント -f develop"              block 'git push -f origin develop'
both "--force-with-lease main"                block 'git push --force-with-lease origin main'
both "プロセス置換に隠した force push"        block 'cat <(git push --force origin main)'
both "連鎖の後半が force push"                block 'echo x && git push --force origin main'
# 暗黙ブランチは current を読むので、Codex 行もここだけ develop fixture で回す
for c in 'git push --force' 'git push --force origin'; do
  run_case "$PB" protect-branches "暗黙ブランチ（develop 上）: $c" block "$c"
  run_case "$PG" git-push-guard   "暗黙ブランチ（develop 上）: $c" block "$c"
  run_case "$CX" codex            "暗黙ブランチ（develop 上）: $c" block "$c" "$FIX"
done
# Codex は旧版でプロセス置換 `cat <(git push --force origin main)` を allow していた。
# ref_targets_protected が保護名の直後に `[[:space:]]|$` を要求し、`main)` の `)` で
# 境界が取れずに素通りしていた（2026-09-05 実測）。セグメント化で `)` が区切りになり
# `main` が行末に来て捕まる。上の F1「プロセス置換に隠した force push」の codex 行が固定する。

echo ""
echo "=== F2 陰性対照: force フラグと保護名が別セグメント ==="
both "事故入力 1: pkill -f + push feature + gh pr --base develop" allow \
  "pkill -f 'codex-run' && git push -u origin fix/x && gh pr create --base develop --head fix/x --title t --body-file b"
both "事故入力 2: 通常 push + pkill -f（develop 上）" allow \
  'git push origin feat/x && pkill -f foo'
both "事故入力 3: 通常 push + grep -f + main.c"      allow \
  'git push -u origin feat/x && grep -f patterns main.c'
both "事故入力 4: force push は feature、main は別セグメント" allow \
  'git push --force origin feat/x && git log origin/main -1'
both "事故入力 5: feature へ force-with-lease + gh pr --base develop" allow \
  'git push --force-with-lease origin feat/x && gh pr create --base develop --head feat/x --title t'
both "統制: force フラグ無しの通常 push"             allow 'git push origin feat/x'

echo ""
echo "=== F3 順序対称: 同じ 2 セグメントを入れ替えても結論が同じ ==="
both "逆順 1: gh pr --base develop && push feature && pkill -f" allow \
  "gh pr create --base develop --head fix/x --title t && git push -u origin fix/x && pkill -f 'codex-run'"
both "逆順 2: pkill -f && 通常 push"                allow \
  'pkill -f foo && git push origin feat/x'
both "逆順 4: git log origin/main && force push feature" allow \
  'git log origin/main -1 && git push --force origin feat/x'
both "逆順 5: gh pr --base develop && feature へ force-with-lease" allow \
  'gh pr create --base develop --head feat/x --title t && git push --force-with-lease origin feat/x'

echo ""
echo "=== F4 片側変異: セグメント化を外すと事故入力が再び block する ==="
# protect-branches: Check 0b のセグメント分割を「全体を 1 セグメント」に戻す
MUT_PB="$FIX/protect-branches.mut.sh"
python3 - "$PB" "$MUT_PB" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "done < <(printf '%s' \"$cmd_norm\" | tr '<>();|&' '\\n')"
# Check 0b のループだけを変異させる（最初の出現 = Check 0b。Check 1/2 は関数内で別）
assert src.count(old) >= 1, "mutation target missing: Check 0b segment loop"
new = "done < <(printf '%s\\n' \"$cmd_norm\")"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
run_case "$MUT_PB" protect-branches "変異版: 事故入力 1 が block へ戻る" block \
  "pkill -f 'codex-run' && git push -u origin fix/x && gh pr create --base develop --head fix/x --title t --body-file b"
run_case "$MUT_PB" protect-branches "変異版: 陽性対照は変わらず block" block 'git push --force origin main'
run_case "$MUT_PB" protect-branches "変異版: 通常 push は変わらず allow" allow 'git push origin feat/x'

# git-push-guard: §1 のセグメント分割を「全体を 1 セグメント」に戻す
MUT_PG="$FIX/git-push-guard.mut.sh"
python3 - "$PG" "$MUT_PG" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "done < <(printf '%s' \"$cmd_norm\" | tr '<>();|&' '\\n')"
assert src.count(old) == 1, "mutation target missing: §1 segment loop (count=%d)" % src.count(old)
new = "done < <(printf '%s\\n' \"$cmd_norm\")"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
# git-push-guard の has_explicit_push_ref() は元からセグメント単位なので、事故入力 2 は
# 旧版でも allow だった（形の欠陥はあったが結論には出ていない）。また mentions_protected_ref
# は `origin/main` を言及に数えない（`/` 前置を除外）ので事故入力 4 も旧版で allow。
# 旧版で実際に落ちるのは「feature への force push と、別セグメントの**裸の**保護名」
# = 事故入力 5（`--base develop`）。これを変異で戻す。
run_case "$MUT_PG" git-push-guard "変異版: 事故入力 5 が block へ戻る" block \
  'git push --force-with-lease origin feat/x && gh pr create --base develop --head feat/x --title t'
run_case "$MUT_PG" git-push-guard "変異版: 陽性対照は変わらず block" block 'git push --force origin main'
run_case "$MUT_PG" git-push-guard "変異版: 通常 push は変わらず allow" allow 'git push origin feat/x'

# codex: push ブロックのセグメント分割を「全体を 1 セグメント」に戻す
MUT_CX="$FIX/protect-branches-codex.mut.sh"
python3 - "$CX" "$MUT_CX" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "done < <(printf '%s' \"$cmd_norm\" | tr '<>();|&' '\\n')"
assert src.count(old) == 1, "mutation target missing: codex push segment loop (count=%d)" % src.count(old)
new = "done < <(printf '%s\\n' \"$cmd_norm\")"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
# codex の ref_targets_protected は `/main` も言及に数えるので、事故入力 4 が旧形で戻る
run_case "$MUT_CX" codex "変異版: 事故入力 4 が block へ戻る" block \
  'git push --force origin feat/x && git log origin/main -1'

echo ""
echo "=== #387: Codex の current は暗黙 push のフォールバックに限定（Cursor 2026-09-03 と同じ）==="
# develop 上で測る。明示の宛先が非保護なら allow、宛先が決められないなら deny。
run_case "$CX" codex "#387 明示 feat/x は allow（develop 上）"          allow 'git push origin feat/x'
run_case "$CX" codex "#387 -u 付き明示 docs/y は allow"                 allow 'git push -u origin docs/y'
run_case "$CX" codex "#387 HEAD:feat/x は dst 側で allow"               allow 'git push origin HEAD:feat/x'
run_case "$CX" codex "#387 refspec 無し（暗黙）は deny"                 block 'git push'
run_case "$CX" codex "#387 origin のみ（暗黙）は deny"                  block 'git push origin'
run_case "$CX" codex "#387 HEAD は current に解決 = 暗黙で deny"        block 'git push -u origin HEAD'
run_case "$CX" codex "#387 明示の保護 ref は従来どおり deny"            block 'git push origin feat/x develop'
run_case "$CX" codex "#387 HEAD:refs/heads/main は deny"                block 'git push origin HEAD:refs/heads/main'
# 片側変異: implicit_push_to_current を無条件の is_protected に戻すと feat/x が再び deny
MUT_CX2="$FIX/protect-branches-codex.mut2.sh"
python3 - "$CX" "$MUT_CX2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '[[ -z "$(push_destination "$1")" ]] && is_protected "$current"'
assert src.count(old) == 1, "mutation target missing: implicit_push_to_current (count=%d)" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'is_protected "$current"'))
PY
run_case "$MUT_CX2" codex "変異版(#387): 明示 feat/x が deny へ戻る" block 'git push origin feat/x'
run_case "$MUT_CX2" codex "変異版(#387): 暗黙は変わらず deny"          block 'git push'
run_case "$MUT_CX" codex "変異版: 陽性対照は変わらず block" block 'git push --force origin main'
run_case "$MUT_CX" codex "変異版: 通常 push は変わらず allow" allow 'git push origin feat/x'

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
