#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/codex/h1-stall-runtime.sh
# H1 北極星の**分子**への結合キー (aidd-governance#155)
#
# 起点: ADR-005 は北極星を「着地 PR 数 / 消費予算」と定義しながら、H1 は
# spend（分母）だけを記録し、delegation → PR を結合する手段を記録していなかった。
# そのため反証条件 2「H1 が発火したが着地 PR が 0 本」が**計算できない**。
# 2026-09-03 実測で block した実運用委任 3 件も、rollout が
# ~/.codex/archived_sessions/ に残っておらず事後の復元ができなかった。
#
# 記録するのは結合キーだけである（repo / branch_start / branches）。
# PR の収集も集計もしない。後から `gh pr list --head <branch>` を回せばよい。
#
# 軸:
#   F1  陽性 — 名前付きブランチ / detached / linked worktree で正しく記録する
#   F2  頑健 — .git が無い・HEAD が壊れている場所で**hook が落ちない**
#              （ガバナが自分の計測のために停止したら本末転倒）
#   F3  片側変異 — record_worktree の呼び出しを外すと state と台帳から消える
#
# F2 が本テストの重心である。分子の記録は**観測**であって判定ではないので、
# 失敗しても allow を返し続けなければならない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test
export CODEX_H1_RESTRICTED_MODELS="*"

HOOK="$ROOT/hooks/codex/h1-stall-runtime.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$SB/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/.claude/hooks/lib/aidd-ledger.sh"

pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; fail=$((fail + 1)); }

payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}
# payload に cwd 欄を持たせる（Codex が渡す場合の形。欄名は候補の 1 つ）
payload_cwd() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"
}
# run_nocwdenv <hook> <delegation> <process-cwd> <payload-json>
#   CODEX_H1_CWD を **渡さない**。process cwd と payload の cwd を独立に制御する。
run_nocwdenv() {
  local hook="$1" delegation="$2" pcwd="$3" json="$4"
  printf '%s' "$json" | (cd "$pcwd" && env HOME="$SB" \
    CODEX_H1_DELEGATION="$delegation" \
    CODEX_H1_SESSIONS_DIR="$SB/no-sessions" \
    bash "$hook")
}
# run <hook> <delegation> <cwd> <cmd> [extra env...]
run() {
  local hook="$1" delegation="$2" cwd="$3" cmd="$4"; shift 4
  payload "$cmd" | env HOME="$SB" \
    CODEX_H1_DELEGATION="$delegation" \
    CODEX_H1_SESSIONS_DIR="$SB/no-sessions" \
    CODEX_H1_CWD="$cwd" \
    "$@" bash "$hook"
}
> "$LEDGER" 2>/dev/null || { mkdir -p "$(dirname "$LEDGER")"; : > "$LEDGER"; }
# hook は Codex の PreToolUse プロトコル JSON を出す。allow は `{}`。
decision_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("malformed"); raise SystemExit(0)
print(d.get("hookSpecificOutput", {}).get("permissionDecision", "allow"))
'
}
state_field() { # state_field <delegation> <python expr on `s`>
  python3 - "$SB/.codex/hooks/h1-state/$1.json" "$2" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("<no-state>"); raise SystemExit(0)
print(eval(sys.argv[2], {"s": s, "json": json}))
PY
}

# --- fixtures -----------------------------------------------------------
mk_repo() { # mk_repo <dir> <branch>
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD "refs/heads/$2"
  git -C "$1" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
}
mk_repo "$SB/named" "feat/numerator"
mk_repo "$SB/wt-main" "develop"
# linked worktree: .git は**ファイル**になり gitdir: を指す
git -C "$SB/wt-main" worktree add -q -b "feat/linked" "$SB/wt-linked" >/dev/null 2>&1
# detached
mk_repo "$SB/det" "main"
DET_SHA="$(git -C "$SB/det" rev-parse HEAD)"
git -C "$SB/det" checkout -q --detach "$DET_SHA"
# 非 git
mkdir -p "$SB/plain"

echo "=== 前提: fixture が想定どおりか（空振り防止）==="
[ -f "$SB/wt-linked/.git" ] && ok "linked worktree の .git はファイルである" \
                            || bad "linked worktree の .git がファイルでない — この節は無意味"
[ -d "$SB/named/.git" ] && ok "通常リポジトリの .git はディレクトリである" \
                        || bad "通常リポジトリの .git がディレクトリでない"

echo ""
echo "=== F1 陽性: 完了条件 1 — state に repo / branch_start / branches が入る ==="
out=$(run "$HOOK" k-named "$SB/named" "ls -la"); dec=$(decision_of "$out")
[ "$dec" = "allow" ] && ok "名前付きブランチで allow" || bad "allow でない: $dec"
[ "$(state_field k-named 's["repo"]')" = "named" ] \
  && ok "repo=named を記録した" || bad "repo が違う" "$(state_field k-named 's.get(\"repo\")')"
[ "$(state_field k-named 's["branch_start"]')" = "feat/numerator" ] \
  && ok "branch_start=feat/numerator を記録した" || bad "branch_start が違う" "$(state_field k-named 's.get(\"branch_start\")')"
[ "$(state_field k-named 'json.dumps(s["branches"])')" = '["feat/numerator"]' ] \
  && ok "branches に 1 件入った" || bad "branches が違う" "$(state_field k-named 'json.dumps(s.get(\"branches\"))')"

echo ""
echo "--- linked worktree は**自分の**ブランチを記録する（親のではない）---"
run "$HOOK" k-linked "$SB/wt-linked" "ls" >/dev/null
b="$(state_field k-linked 's["branch_start"]')"
[ "$b" = "feat/linked" ] && ok "linked worktree で feat/linked を記録" \
                         || bad "linked worktree のブランチが違う（親を読んでいる可能性）" "$b"

echo ""
echo "--- detached HEAD は sha として記録する（空にしない）---"
run "$HOOK" k-det "$SB/det" "ls" >/dev/null
b="$(state_field k-det 's["branch_start"]')"
case "$b" in
  detached:*) ok "detached:<sha> を記録した -- ${b}" ;;
  *) bad "detached を記録できていない" "$b" ;;
esac

echo ""
echo "--- ブランチを切り替えると branches に積む（1 委任 = 複数ブランチ）---"
git -C "$SB/named" checkout -q -b "feat/second"
run "$HOOK" k-named "$SB/named" "ls" >/dev/null
js="$(state_field k-named 'json.dumps(s["branches"])')"
[ "$js" = '["feat/numerator", "feat/second"]' ] \
  && ok "branches に 2 件目が積まれた" || bad "branches が想定と違う" "$js"
[ "$(state_field k-named 's["branch_start"]')" = "feat/numerator" ] \
  && ok "branch_start は最初のまま（開始点が保たれる）" || bad "branch_start が上書きされた"

echo ""
echo "=== F2 頑健: 決められない場所でも hook は落ちない（allow を返す）==="
out=$(run "$HOOK" k-plain "$SB/plain" "ls"); dec=$(decision_of "$out")
[ "$dec" = "allow" ] && ok "非 git ディレクトリで allow" || bad "非 git で allow でない" "$dec"
[ "$(state_field k-plain 's.get("repo","")')" = "" ] \
  && ok "非 git では repo が空（誤った値を作らない）" || bad "非 git なのに repo がある"

# HEAD を壊す
printf 'garbage-not-a-ref\n' > "$SB/named/.git/HEAD"
out=$(run "$HOOK" k-broken "$SB/named" "ls"); dec=$(decision_of "$out")
[ "$dec" = "allow" ] && ok "HEAD が壊れていても allow" || bad "HEAD 破損で allow でない" "$dec"
[ "$(state_field k-broken 's.get("branch_start","")')" = "" ] \
  && ok "HEAD 破損では branch_start が空（推測しない）" || bad "破損 HEAD から値を作った"
# 存在しない cwd
out=$(run "$HOOK" k-missing "$SB/does-not-exist" "ls"); dec=$(decision_of "$out")
[ "$dec" = "allow" ] && ok "存在しない cwd でも allow" || bad "存在しない cwd で落ちた" "$dec"

echo ""
echo "=== F4 cwd の出所（aidd-governance#155 の 40% 欠測への是正）==="
# 実 Codex は CODEX_H1_CWD を渡さない。process cwd が非 git でも payload に cwd が
# あればそれで解決できることを固定する。統制として payload に cwd が無ければ
# process cwd に落ちて空になる（= 修正前の挙動、欠測の再現）。
out=$(run_nocwdenv "$HOOK" k-pcwd "$SB/plain" "$(payload_cwd "ls" "$SB/named")"); dec=$(decision_of "$out")
[ "$dec" = "allow" ] && ok "payload cwd 経路で allow" || bad "payload cwd 経路で allow でない" "$dec"
[ "$(state_field k-pcwd 's.get("repo","")')" = "named" ] \
  && ok "process cwd が非 git でも payload の cwd から repo=named を解決した" \
  || bad "payload の cwd が使われていない" "$(state_field k-pcwd 's.get(\"repo\")')"
out=$(run_nocwdenv "$HOOK" k-pcwd-ctl "$SB/plain" "$(payload "ls")"); dec=$(decision_of "$out")
[ "$(state_field k-pcwd-ctl 's.get("repo","")')" = "" ] \
  && ok "統制: payload に cwd が無く process cwd が非 git なら空（欠測の再現）" \
  || bad "統制が成立しない — 何かが cwd を補っている" "$(state_field k-pcwd-ctl 's.get(\"repo\")')"
# 優先順: 明示 env は payload より強い
out=$(printf '%s' "$(payload_cwd "ls" "$SB/plain")" | (cd "$SB/plain" && env HOME="$SB" \
  CODEX_H1_DELEGATION=k-prio CODEX_H1_SESSIONS_DIR="$SB/no-sessions" CODEX_H1_CWD="$SB/named" bash "$HOOK"))
[ "$(state_field k-prio 's.get("repo","")')" = "named" ] \
  && ok "優先順: CODEX_H1_CWD(named) > payload cwd(plain)" \
  || bad "優先順が逆" "$(state_field k-prio 's.get(\"repo\")')"

echo ""
echo "=== 完了条件 2: block 行の subject に結合キーが載る ==="
mkdir -p "$SB/.codex/hooks/h1-state"
python3 - "$SB" <<'PY'
import json, os, time
sb = os.sys.argv[1]
now = int(time.time())
p = os.path.join(sb, ".codex", "hooks", "h1-state")
os.makedirs(p, exist_ok=True)
json.dump({"delegation": "k-block", "started_ts": now - 60, "last_progress_ts": now,
           "iterations": 0, "tool_calls": 1, "spend_tokens": 0, "spend_usd": 99.0,
           "budget_usd": 5.0, "budget_source": "proxy:toolcalls", "max_iterations": 10,
           "no_progress_sec": 2700, "last_cmd_sha256": "", "same_cmd_streak": 0,
           "last_warn_80": 0, "last_heartbeat_ts": now, "last_block_rule": "",
           "last_block_ts": 0},
          open(os.path.join(p, "k-block.json"), "w"))
PY
: > "$LEDGER"
# spend は measure_spend が seed 値を上書きするので、**予算側**を下げて確実に超過させる。
# proxy:toolcalls でも 1 回の呼び出しで超える値にする。
out=$(run "$HOOK" k-block "$SB/wt-linked" "ls" CODEX_H1_BUDGET_USD=0.000001)
dec=$(decision_of "$out")
[ "$dec" = "deny" ] && ok "予算超過で block した（この節の前提）" || bad "block しない — 以降は無意味" "$dec"
# 記録は stdout ではなく防御台帳へ届く（H6 要件 4）。台帳を読む。
sub="$(python3 - "$LEDGER" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("component") == "H1" and o.get("event") == "block":
        s = o.get("subject", {})
        print(json.dumps({k: s.get(k) for k in ("repo", "branch_start", "branches")},
                         ensure_ascii=False))
        break
PY
)"
echo "        subject の結合キー: ${sub:-<なし>}"
case "$sub" in
  *'"repo": "wt-linked"'*|*'"repo":"wt-linked"'*) ok "block 行の subject に repo が載る" ;;
  *) bad "block 行に repo が無い" "$sub" ;;
esac
case "$sub" in
  *feat/linked*) ok "block 行の subject に branch が載る" ;;
  *) bad "block 行に branch が無い" "$sub" ;;
esac

echo ""
echo "=== F3 片側変異: 記録を外すと state と台帳から消える ==="
MUT="$SB/mut-nojoin.sh"
python3 - "$HOOK" "$MUT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "    record_worktree(state)\n"
assert src.count(old) == 1, "record_worktree の呼び出し形が変わっている（変異が当たらない）"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, ""))
PY
if bash -n "$MUT" 2>/dev/null; then
  ok "変異版が構文として成立している"
  # 統制: 変異版でも hook は動く（allow を返す）。動かないなら「差が出た」ではない。
  out=$(run "$MUT" m-named "$SB/wt-linked" "ls"); dec=$(decision_of "$out")
  [ "$dec" = "allow" ] && ok "変異版は動いている（allow を返す）" \
                       || bad "変異版が動いていない — 以下は「差」ではなく「故障」" "$dec"
  v="$(state_field m-named 's.get("repo","<absent>")')"
  [ "$v" = "<absent>" ] && ok "変異版では repo が記録されない（記録は結論を作っていた）" \
                        || bad "変異版でも repo がある — この記録は変異と無関係" "$v"
  v="$(state_field m-named 's.get("branch_start","<absent>")')"
  [ "$v" = "<absent>" ] && ok "変異版では branch_start が記録されない" \
                        || bad "変異版でも branch_start がある" "$v"
else
  bad "変異版の生成に失敗（この節の結果は無意味）"
fi

echo ""
echo "=== 完了条件 5 の総括: 判定を変えていない ==="
# 記録の有無で allow/deny が変わってはならない（観測であって判定ではない）。
same=1
for cwd in "$SB/named" "$SB/plain" "$SB/wt-linked"; do
  a=$(decision_of "$(run "$HOOK" cmp-a-$$ "$cwd" "ls")")
  b=$(decision_of "$(run "$MUT" cmp-b-$$ "$cwd" "ls")")
  [ "$a" = "$b" ] || { same=0; bad "記録の有無で判定が変わった -- cwd=${cwd} 本体=${a} 変異=${b}"; }
done
[ "$same" -eq 1 ] && ok "記録の有無で allow/deny は変わらない（観測であって判定ではない）"

echo ""
echo "=== PASS=$pass FAIL=$fail ==="
[ "$fail" -eq 0 ]
