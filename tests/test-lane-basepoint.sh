#!/usr/bin/env bash
# 並列レーンの基点検査 — scripts/lane-basepoint-check.sh の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#91
#
# 起点事故 (2026-08-26〜27, Grift Phase B): 既存 worktree の基点が数時間前の
# develop のまま 4 レーンを同時起動した。その間に PR #2115 / #2136 の成果が
# develop へ入っていたため、feat/l-s6-api は同じ 4 ファイルを独立に再実装し、
# マージ時に add/add 競合 4 件。delivery_incident_judgment_store.go は
# develop 650 行 対 ブランチ 290 行で、ブランチ側がまるごと破棄された。
#
# 本スイートは実際の git リポジトリを組み立てて事故の形をそのまま再現する。
# 「宣言どおり止まるか」ではなく「止めている条件を外すと素通しするか」まで
# 実測する。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/lane-basepoint-check.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
export HOME="$SB/home"
mkdir -p "$HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

git_q() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }

# build_fixture <name> — origin (bare) + develop 1 commit を持つ clone を作る。
# 返り値: clone のパスを stdout へ。
build_fixture() {
  local name="$1" origin="$SB/$1-origin.git" work="$SB/$1-work"
  git init --quiet --bare --initial-branch=develop "$origin"
  git init --quiet --initial-branch=develop "$work"
  git_q "$work" remote add origin "$origin"
  printf 'seed\n' >"$work/README.md"
  git_q "$work" add README.md
  git_q "$work" commit --quiet -m "seed"
  git_q "$work" push --quiet -u origin develop
  printf '%s' "$work"
}

# advance_base <work> <file> — origin/develop 側を 1 commit 進める（他レーンの着地）。
advance_base() {
  local work="$1" file="$2" other="$SB/other-$RANDOM"
  git clone --quiet "$(git_q "$work" remote get-url origin)" "$other"
  printf 'develop side implementation, mature\n' >"$other/$file"
  git_q "$other" add "$file"
  git_q "$other" commit --quiet -m "other lane landed $file"
  git_q "$other" push --quiet origin develop
  rm -rf "$other"
}

run_check() {
  # run_check <mode> <worktree> [env...] — stdout/stderr を捨てて rc だけ返す。
  local mode="$1" wt="$2"
  shift 2
  env "$@" bash "$CHECK" "$mode" "$wt" >>"$SB/out.log" 2>&1
}

ledger_has() {
  # ledger_has <rule> <event>
  python3 - "$LEDGER" "$1" "$2" <<'PY'
import json, os, sys
path, rule, event = sys.argv[1:4]
if not os.path.exists(path):
    raise SystemExit(1)
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("rule") == rule and row.get("event") == event:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "=== case 1: 基点が base tip と一致 -> pass ==="
W=$(build_fixture c1)
git_q "$W" checkout --quiet -b feat/lane-a
if run_check basepoint "$W" LANE_BASE=develop; then
  ok "case1 最新基点は素通しする（恒真 red ではない）"
else
  bad "case1 最新基点なのに block した"
fi

echo
echo "=== case 2: 基点が古い（他レーンが base へ着地した後） -> block ==="
echo "    Grift #91 replay: worktree の基点が数時間前の develop のまま"
W=$(build_fixture c2)
git_q "$W" checkout --quiet -b feat/l-s6-api
advance_base "$W" "delivery_incident_judgment_store.go"
git_q "$W" fetch --quiet origin develop
if run_check basepoint "$W" LANE_BASE=develop; then
  bad "case2 基点が古いのに素通しした"
else
  ok "case2 基点が 1 commit 古いだけで block した"
fi
ledger_has stale-basepoint block \
  && ok "case2 台帳に rule=stale-basepoint event=block 行" \
  || bad "case2 台帳に stale-basepoint block 行がない"
python3 - "$LEDGER" <<'PY' && ok "case2 台帳 subject が behind 実測値を持つ" || bad "case2 subject に behind がない"
import json, sys
rows = [json.loads(x) for x in open(sys.argv[1], encoding="utf-8") if x.strip()]
rows = [r for r in rows if r.get("rule") == "stale-basepoint" and r.get("event") == "block"]
assert rows, "no block row"
subj = rows[-1]["subject"]
assert int(subj["behind"]) >= 1, subj
assert subj["base"] == "origin/develop", subj
PY

echo
echo "=== case 3: add/add — 両側が独立に同じファイルを新規作成 -> block ==="
W=$(build_fixture c3)
git_q "$W" checkout --quiet -b feat/l-s6-api
# レーン側の実装（未成熟な 290 行相当）
printf 'branch side implementation\n' >"$W/delivery_incident_judgment_store.go"
git_q "$W" add delivery_incident_judgment_store.go
git_q "$W" commit --quiet -m "lane implements judgment store"
# 同じファイルが base 側にも独立に着地する
advance_base "$W" "delivery_incident_judgment_store.go"
git_q "$W" fetch --quiet origin develop
if run_check duplicates "$W" LANE_BASE=develop; then
  bad "case3 add/add 競合を素通しした"
else
  ok "case3 add/add をマージ前に検出して block した"
fi
python3 - "$LEDGER" <<'PY' && ok "case3 台帳が重複ファイル名を列挙する" || bad "case3 台帳に duplicate_files がない"
import json, sys
rows = [json.loads(x) for x in open(sys.argv[1], encoding="utf-8") if x.strip()]
rows = [r for r in rows if r.get("rule") == "duplicate-implementation" and r.get("event") == "block"]
assert rows, "no duplicate block row"
files = rows[-1]["subject"]["duplicate_files"]
assert "delivery_incident_judgment_store.go" in files, files
PY

echo
echo "=== case 4: 真に新規なファイルだけ -> duplicates は pass ==="
W=$(build_fixture c4)
git_q "$W" checkout --quiet -b feat/lane-b
printf 'genuinely new\n' >"$W/delivery_clock_store.go"
git_q "$W" add delivery_clock_store.go
git_q "$W" commit --quiet -m "lane adds a file base does not have"
advance_base "$W" "unrelated_other.go"
git_q "$W" fetch --quiet origin develop
if run_check duplicates "$W" LANE_BASE=develop; then
  ok "case4 分離した新規ファイルは素通しする（恒真 red ではない）"
else
  bad "case4 重複していないのに block した"
fi

echo
echo "=== case 5: LANE_BASEPOINT_ENFORCE=0 は降格するが、降格自体を記帳する ==="
W=$(build_fixture c5)
git_q "$W" checkout --quiet -b feat/lane-c
advance_base "$W" "later.go"
git_q "$W" fetch --quiet origin develop
if run_check basepoint "$W" LANE_BASE=develop LANE_BASEPOINT_ENFORCE=0; then
  ok "case5 降格指定で exit 0 になる"
else
  bad "case5 降格指定が効いていない"
fi
ledger_has basepoint-bypassed warn \
  && ok "case5 降格の事実が台帳へ残る（黙って外せない）" \
  || bad "case5 降格したのに台帳へ残らない"

echo
echo "=== case 6: base 自動解決（origin/HEAD 不在でも develop へ落ちる） ==="
W=$(build_fixture c6)
git_q "$W" checkout --quiet -b feat/lane-d
if run_check basepoint "$W"; then
  ok "case6 LANE_BASE 未指定でも develop を解決して判定した"
else
  bad "case6 base 自動解決に失敗した"
fi

echo
echo "=== 変異体: 判定条件を外すと case2 / case3 が素通しすることの実測 ==="
MUT="$SB/mutants"
mkdir -p "$MUT"
mutate() {
  python3 - "$CHECK" "$1" "$2" "$3" <<'PY'
import sys
src, needle, replacement, out = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if needle not in text:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(text.replace(needle, replacement, 1))
PY
}

if mutate 'if [ "$behind" -le "$BEHIND_LIMIT" ]; then' 'if true; then' "$MUT/behind.sh"; then
  W=$(build_fixture m1)
  git_q "$W" checkout --quiet -b feat/lane-m1
  advance_base "$W" "x.go"
  git_q "$W" fetch --quiet origin develop
  if env LANE_BASE=develop bash "$MUT/behind.sh" basepoint "$W" >/dev/null 2>&1; then
    ok "変異(behind 比較除去) 古い基点が素通しする = 比較は効いていた"
  else
    bad "変異(behind 比較除去) それでも block = case2 は別条件が出している"
  fi
else
  bad "変異(behind 比較除去) 対象が見つからない — 反証不能"
fi

if mutate 'if git -C "$wt" cat-file -e "origin/$base:$path" 2>/dev/null; then' \
          'if false; then' "$MUT/dupe.sh"; then
  W=$(build_fixture m2)
  git_q "$W" checkout --quiet -b feat/lane-m2
  printf 'branch side\n' >"$W/dup.go"
  git_q "$W" add dup.go
  git_q "$W" commit --quiet -m "lane adds dup.go"
  advance_base "$W" "dup.go"
  git_q "$W" fetch --quiet origin develop
  if env LANE_BASE=develop bash "$MUT/dupe.sh" duplicates "$W" >/dev/null 2>&1; then
    ok "変異(同名存在判定除去) add/add が素通しする = 判定は効いていた"
  else
    bad "変異(同名存在判定除去) それでも block = case3 は別条件が出している"
  fi
else
  bad "変異(同名存在判定除去) 対象が見つからない — 反証不能"
fi

echo
echo "=== 宣言↔強制 pair: codex-parallel.sh が発射前にゲートを呼ぶこと ==="
WRAPPER="$ROOT/scripts/codex-parallel.sh"
python3 - "$WRAPPER" <<'PY' && ok "pair codex-parallel.sh は worktree 作成後・実装 codex 起動前にゲートを呼ぶ" || bad "pair ゲートの位置が誤り、または不在"
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()

def find(pred, what):
    idx = next((i for i, l in enumerate(lines) if pred(l)), None)
    assert idx is not None, "%s not found" % what
    return idx

# review モード (-C "$REPO_PATH") は worktree を作らないのでゲートの対象外。
# 対象は実装モードの起動 = worktree を cwd にする codex exec だけ。
created = find(lambda l: l.strip().startswith("git -C \"$REPO_PATH\" worktree add"), "worktree add")
gate = find(lambda l: "LANE_CHECK=" in l and "lane-basepoint-check.sh" in l, "gate call")
impl = find(lambda l: l.strip() == '-C "$WORKTREE_PATH" \\', "implementation launch")
assert created < gate, "gate at %d runs before worktree add at %d" % (gate + 1, created + 1)
assert gate < impl, "gate at %d is AFTER the implementation launch at %d" % (gate + 1, impl + 1)
PY
python3 - "$WRAPPER" <<'PY' && ok "pair ゲート失敗時に exit する（警告だけで発射しない）" || bad "pair ゲート失敗が発射を止めていない"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
block = text.split("LANE_CHECK=", 1)[1].split("# --- Build full prompt", 1)[0]
assert "exit 1" in block, "gate failure does not exit:\n" + block
PY
# exec ビットが落ちてもゲートが無効化されないこと（-f 判定 + bash 起動）。
python3 - "$WRAPPER" <<'PY' && ok "pair exec ビット非依存で起動する（-f 判定 + bash 起動）" || bad "pair -x 判定のため exec ビット喪失でゲートが黙って消える"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
block = text.split("LANE_CHECK=", 1)[1].split("# --- Build full prompt", 1)[0]
assert '[[ -f "$LANE_CHECK" ]]' in block, "not using -f test"
assert 'bash "$LANE_CHECK"' in block, "not invoking via bash"
PY

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
