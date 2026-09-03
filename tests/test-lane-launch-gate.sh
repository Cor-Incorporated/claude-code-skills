#!/usr/bin/env bash
# レーン発射ゲート — hooks/lane-launch-gate.sh の反証テスト.
#
# Issue: Cor-Incorporated/aidd-governance#91（基点規律）, #88（同族反復上限）
#
# 2026-09-02 実測: 当日 11 worktree のうち 10 本が behind=0 だったのは規律では
# なく時刻である（7:45 に同一 head から一斉起動）。3 PR が着地した後に起動した
# 1 本だけが 6 commit 遅れた。本スイートはその形をそのまま再現する。
#
# 「止まること」だけでなく「止めている条件を外すと素通しすること」まで実測する。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/lane-launch-gate.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
REAL_HOME="$HOME"   # HOME を差し替える前に捕まえる（#88 の breaker 探索に使う）
export HOME="$SB/home"
mkdir -p "$HOME/.claude/hooks/lib"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$HOME/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

git_q() { git -C "$1" -c user.email=t@e.c -c user.name=t "${@:2}"; }

payload() { python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }

# run_gate <hook> <command> [env...] -> rc、stderr は $SB/err
run_gate() {
  local hook="$1" cmd="$2"
  shift 2
  payload "$cmd" | env "$@" bash "$hook" 2>"$SB/err"
}

ledger_has() {
  python3 - "$LEDGER" "$1" <<'PY'
import json, os, sys
path, rule = sys.argv[1:3]
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
    if row.get("rule") == rule:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# --- fixture: origin(bare, base=trunk) + clone -------------------------------
# base 名に develop/main を使わない。git-push-guard.sh が fixture の push を
# 保護ブランチへの直接 push と誤認するため（本物の保護であって、回避ではない）。
ORIGIN="$SB/o.git"; REPO="$SB/repo"
git init -q --bare -b trunk "$ORIGIN"
git init -q -b trunk "$REPO"
git_q "$REPO" remote add origin "$ORIGIN"
printf 'seed\n' >"$REPO/README.md"
git_q "$REPO" add README.md
git_q "$REPO" commit -qm seed
git_q "$REPO" push -q -u origin trunk
FRESH="$(git_q "$REPO" rev-parse HEAD)"

# 他レーンが trunk へ着地する（= 経過時間でずれが生まれる形）
OTHER="$SB/other"
git clone -q "$ORIGIN" "$OTHER"
printf 'landed by another lane\n' >"$OTHER/store.go"
git_q "$OTHER" add store.go
git_q "$OTHER" commit -qm "other lane landed"
git_q "$OTHER" push -q origin trunk
git_q "$REPO" fetch -q origin trunk

export LANE_BASE=trunk

echo "=== case 1: 最新の起点 -> allow（恒真 block ではない） ==="
if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/x -b feat/a origin/trunk" LANE_BASE=trunk HOME="$HOME"; then
  ok "case1 origin/trunk 起点は素通しする"
else
  bad "case1 最新起点なのに block した (rc=$?): $(cat "$SB/err")"
fi

echo
echo "=== case 2: 古い起点 -> deny（#91 replay: 着地後に起動したレーン） ==="
run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/y -b feat/b $FRESH" LANE_BASE=trunk HOME="$HOME"
rc=$?
[[ "$rc" -eq 2 ]] \
  && ok "case2 1 commit 古い起点を exit 2 で拒否した" \
  || bad "case2 期待 exit 2, 実際 rc=$rc"
grep -q "基点規律" "$SB/err" \
  && ok "case2 拒否理由が #91 の規律であると明示する" \
  || bad "case2 拒否理由が不明瞭: $(cat "$SB/err")"
grep -qE "1 commit 古い|behind" "$SB/err" \
  && ok "case2 拒否理由が behind の実測値を含む" \
  || bad "case2 behind の実測値がない"
ledger_has stale-basepoint \
  && ok "case2 台帳に stale-basepoint 行" \
  || bad "case2 台帳に stale-basepoint 行がない"

echo
echo "=== case 3: 起点省略 -> allow するが、省略したことを黙らない ==="
if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/z -b feat/c" LANE_BASE=trunk HOME="$HOME"; then
  ok "case3 起点省略は通す（新規レーンを作れなくしない）"
else
  bad "case3 起点省略で block した"
fi
grep -q "起点未指定" "$SB/err" \
  && ok "case3 省略したことを stderr で告げる（黙って通さない）" \
  || bad "case3 省略が無言だった"
ledger_has basepoint-skipped \
  && ok "case3 省略を台帳へ measure で残す" \
  || bad "case3 省略が台帳に残らない"

echo
echo "=== case 4: 誤検知しない — 引用・データ文脈・別サブコマンド ==="
for c in \
  'git commit -m "add worktree add support"' \
  'grep -rn "git worktree add" docs/' \
  'echo "git worktree add foo bar"' \
  'git worktree list' \
  "git -C $REPO worktree remove $REPO/.worktrees/a/x" \
  'rg --files-with-matches "git worktree add"' ; do
  if run_gate "$HOOK" "$c" LANE_BASE=trunk HOME="$HOME"; then
    ok "case4 誤検知なし: ${c:0:46}"
  else
    bad "case4 誤発火した: $c"
  fi
done

echo
echo "=== case 5: 二重発火しない — 経路 C は wrapper 側だけが検査する ==="
if run_gate "$HOOK" "bash scripts/codex-parallel.sh $REPO feat/x 'task'" LANE_BASE=trunk HOME="$HOME"; then
  ok "case5 codex-parallel.sh 呼び出しでは hook が発火しない（wrapper 側と排他）"
else
  bad "case5 codex-parallel.sh でも hook が発火 = 二重検査になっている"
fi
python3 - "$ROOT/scripts/codex-parallel.sh" <<'PY' && ok "case5 wrapper 側のゲートは存置されている（片側だけにしない）" || bad "case5 wrapper 側のゲートが消えている"
import sys
t = open(sys.argv[1], encoding="utf-8").read()
assert "lane-basepoint-check.sh" in t, "wrapper gate missing"
PY

echo
RLED="$SB/repair.jsonl"
echo "=== case 6 (#88): 同族反復。判定は aidd-governance の breaker を呼ぶ ==="
# breaker は aidd-governance が正本。REAL_HOME は HOME を差し替える前に捕まえた値。
# 見つからない環境（CI ランナー）では #88 ケースを skip し、skip したと明示する。
BREAKER=""
for cand in "${AIDD_GOV_REPO:-}/scripts/repair-loop-breaker.sh" \
            "$REAL_HOME/Developer/aidd-governance/scripts/repair-loop-breaker.sh"; do
  if [ -f "$cand" ]; then BREAKER="$cand"; break; fi
done
if [ -z "$BREAKER" ]; then
  echo "SKIP: repair-loop-breaker.sh が見つからないため #88 ケースを省略（CI では正常）"
else
  # 直近の時刻で seed する。breaker には stage-stall（stage 無変化 90 分 + その後の
  # repair）という別ルールもあり、古い固定時刻だと prior=2 でもそちらが発火して
  # 「N=3 で止まった」ことの証明にならない（実測で踏んだ）。
  seed_repairs() {
    : >"$RLED"
    local n="$1" i ts
    ts="$(python3 -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()-60)))')"
    printf '{"ts":"%s","family":"infra","kind":"stage","ref":"s0","stage":"merged"}\n' "$ts" >>"$RLED"
    for i in $(seq 1 "$n"); do
      ts="$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(time.time()-50+$i)))")"
      printf '{"ts":"%s","family":"infra","kind":"repair-pr","ref":"p%d","outcome":"merged"}\n' "$ts" "$i" >>"$RLED"
    done
  }
  # family "infra" を導出させるため infra/ 配下のパスを宣言する
  seed_repairs 2
  if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/p1 -b feat/p1 origin/trunk" \
      LANE_BASE=trunk HOME="$HOME" LANE_PATHS="infra/main.tf" \
      LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$RLED"; then
    ok "case6 prior=2 は発射できる（恒真 block ではない）"
  else
    bad "case6 prior=2 なのに block した: $(cat "$SB/err")"
  fi
  seed_repairs 3
  run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/p2 -b feat/p2 origin/trunk" \
    LANE_BASE=trunk HOME="$HOME" LANE_PATHS="infra/main.tf" \
    LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$RLED"
  rc=$?
  [[ "$rc" -eq 2 ]] \
    && ok "case6 N=3 到達で発射を拒否した" \
    || bad "case6 N=3 で拒否しなかった (rc=$rc): $(cat "$SB/err")"
  grep -q "同族反復上限" "$SB/err" \
    && ok "case6 拒否理由が #88 の家系反復であると明示する" \
    || bad "case6 拒否理由が不明瞭"

  echo "--- Grift #2070-#2098 retrodiction: 実インシデント台帳をゲートに通す ---"
  # cluster-a が #88 の完了条件用に作った実データ。PR #2073 の発射時点で N=3 に
  # 達しており、再裁定エントリがあれば解除される。判定は breaker が持つので、
  # ここで確かめるのは「ゲートがその判定を正しく通しているか」だけである。
  GRIFT_LEDGER="$(dirname "$BREAKER")/../design/ops/readjudication/fixtures/grift-2070-2098.jsonl"
  GRIFT_ENTRY="$(dirname "$BREAKER")/../design/ops/readjudication/fixtures/entry-valid.md"
  if [ -f "$GRIFT_LEDGER" ] && [ -f "$GRIFT_ENTRY" ]; then
    run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/g1 -b feat/g1 origin/trunk" \
      LANE_BASE=trunk HOME="$HOME" \
      LANE_PATHS="services/control-api/internal/migrationbootstrap/x.go" \
      LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$GRIFT_LEDGER"
    [[ "$?" -eq 2 ]] \
      && ok "case6 Grift 実台帳: 再裁定なしの 4 本目レーンを止めた（16 サイクルの起点）" \
      || bad "case6 Grift 実台帳で止まらなかった"
    if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/g2 -b feat/g2 origin/trunk" \
        LANE_BASE=trunk HOME="$HOME" \
        LANE_PATHS="services/control-api/internal/migrationbootstrap/x.go" \
        LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$GRIFT_LEDGER" \
        LANE_READJ_ENTRY="$GRIFT_ENTRY"; then
      ok "case6 Grift 実台帳: 有効な再裁定エントリで解除される（永久ブロックではない）"
    else
      bad "case6 再裁定エントリがあっても解除されない"
    fi
  else
    echo "SKIP: Grift fixture 不在（${GRIFT_LEDGER}）"
  fi

  echo "--- LANE_PATHS 未宣言なら #88 判定は省略される（黙って通さない） ---"
  if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/p3 -b feat/p3 origin/trunk" \
      LANE_BASE=trunk HOME="$HOME" LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$RLED"; then
    ok "case6 LANE_PATHS 未宣言では #88 を判定せず通す（発射時点に diff は無い）"
  else
    bad "case6 宣言なしで block した"
  fi
fi

echo
echo "=== case 7: LANE_BASEPOINT_ENFORCE=0 は降格するが記帳する ==="
if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/w -b feat/w $FRESH" \
    LANE_BASE=trunk HOME="$HOME" LANE_BASEPOINT_ENFORCE=0; then
  ok "case7 降格指定で通る"
else
  bad "case7 降格指定が効かない"
fi
ledger_has basepoint-bypassed \
  && ok "case7 降格の事実が台帳に残る（黙って外せない）" \
  || bad "case7 降格が台帳に残らない"

echo
echo "=== case 8: 依存が解決できないとき — 通すが、黙らない ==="
echo "    壊れた関門で作業を止めるのは正しくない。変えてはいけないのは「黙る」ことだけ。"
echo "    同型: #81 secret-patterns 未配備 / #121 harness-spec 未配布。"
# hook を scripts/ の無いディレクトリへ隔離し、BASEPOINT_SH を解決不能にする。
ISO="$SB/iso"
mkdir -p "$ISO/hooks/lib"
cp "$HOOK" "$ISO/hooks/lane-launch-gate.sh"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$ISO/hooks/lib/aidd-ledger.sh"
if run_gate "$ISO/hooks/lane-launch-gate.sh" \
     "git -C $REPO worktree add $REPO/.worktrees/a/u1 -b feat/u1 $FRESH" \
     LANE_BASE=trunk HOME="$HOME"; then
  ok "case8 basepoint スクリプト不在でも通す（壊れた関門で止めない）"
else
  bad "case8 スクリプト不在で block した"
fi
grep -q "lane-basepoint-check.sh が見つからない" "$SB/err" \
  && ok "case8 スクリプト不在を stderr で告げる（黙って通さない）" \
  || bad "case8 スクリプト不在が無言だった: [$(cat "$SB/err")]"
ledger_has basepoint-unavailable \
  && ok "case8 スクリプト不在を台帳へ measure で残す" \
  || bad "case8 スクリプト不在が台帳に残らない"

if run_gate "$ISO/hooks/lane-launch-gate.sh" \
     "git -C $REPO worktree add $REPO/.worktrees/a/u2 -b feat/u2 origin/trunk" \
     LANE_BASE=trunk HOME="$HOME" LANE_PATHS="infra/main.tf" LANE_BREAKER_SH=""; then
  ok "case8 breaker 不在でも通す"
else
  bad "case8 breaker 不在で block した"
fi
grep -q "repair-loop-breaker.sh が見つからない" "$SB/err" \
  && ok "case8 breaker 不在を stderr で告げる" \
  || bad "case8 breaker 不在が無言だった: [$(cat "$SB/err")]"
ledger_has breaker-absent \
  && ok "case8 breaker 不在を台帳へ measure で残す" \
  || bad "case8 breaker 不在が台帳に残らない"

if [ -n "$BREAKER" ]; then
  if run_gate "$HOOK" "git -C $REPO worktree add $REPO/.worktrees/a/u3 -b feat/u3 origin/trunk" \
       LANE_BASE=trunk HOME="$HOME" LANE_PATHS="infra/main.tf" \
       LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$SB/does-not-exist.jsonl"; then
    ok "case8 修理台帳不在でも通す"
  else
    bad "case8 修理台帳不在で block した"
  fi
  grep -q "修理台帳" "$SB/err" \
    && ok "case8 修理台帳不在を stderr で告げる" \
    || bad "case8 修理台帳不在が無言だった: [$(cat "$SB/err")]"
  ledger_has repair-ledger-absent \
    && ok "case8 修理台帳不在を台帳へ measure で残す" \
    || bad "case8 修理台帳不在が台帳に残らない"
fi

MUTCHK="$SB/mutchk"; mkdir -p "$MUTCHK"
echo "--- 網羅性: 素通しする分岐はすべて記録を残すこと（無言経路ゼロ） ---"
# 抽出は正規表現の findall ではなく行走査で行う。findall は非重複なので、直前の
# 分岐のキャプチャが末尾改行まで食い、**隣接する elif を 1 本おきに取りこぼす**
# （検収指摘で実測: 実際 3 本に対し 2 本しか見ていなかった）。
# 行走査なら隣接は構造上取りこぼさない。
silent_check() {
  python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("# --- (1) #91 基点規律"):src.index("done <<")]
lines = body.splitlines()
branches, i = [], 0
while i < len(lines):
    if re.match(r"^  (?:elif|else)\b", lines[i]):
        hdr, blk = lines[i], []
        i += 1
        while i < len(lines) and not re.match(r"^  (?:elif|else|fi)\b", lines[i]):
            blk.append(lines[i]); i += 1
        branches.append((hdr, "\n".join(blk)))
    else:
        i += 1
if not branches:
    print("no branches found - extraction is broken", file=sys.stderr)
    raise SystemExit(2)
# 判定を省略して通す分岐は note_ledger と stderr の両方を持たねばならない。
missing = [h.strip() for h, b in branches
           if "emit_deny" not in b and ("note_ledger" not in b or ">&2" not in b)]
if missing:
    print("silent skip branches: %r" % missing, file=sys.stderr)
    raise SystemExit(1)
print("branches=%d all recorded" % len(branches))
PY
}
if silent_check "$HOOK" >/dev/null 2>&1; then
  ok "無言で素通しする分岐が残っていない ($(silent_check "$HOOK"))"
else
  bad "記録の無い素通し分岐がある: $(silent_check "$HOOK" 2>&1)"
fi

echo "--- 網羅性照合そのものの陰性テスト（検査器を反証する） ---"
# 検査器を作っただけでは「検査していないのに緑」を検出できない。無言の elif を
# 実際に注入して red になることを実測する。注入位置は 2 通り —
# (a) 既存分岐の直前（隣接。findall 版が取りこぼしていた位置）
# (b) 末尾の分岐の直前。
inject_silent() {
  python3 - "$HOOK" "$1" "$2" <<'PY'
import re, sys
src_path, out, anchor = sys.argv[1:4]
src = open(src_path, encoding="utf-8").read()
probe = '  elif [ -n "${LANE_SILENT_PROBE:-}" ]; then\n    :\n'
m = re.search(anchor, src, re.M)
if not m:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(src[:m.start()] + probe + src[m.start():])
PY
}
if inject_silent "$MUTCHK/adjacent.sh" '^  elif \[ -z "\$start" \]; then'; then
  if silent_check "$MUTCHK/adjacent.sh" >/dev/null 2>&1; then
    bad "陰性(隣接注入) 無言 elif を既存分岐の直前へ入れても緑 = 検査器が見ていない"
  else
    ok "陰性(隣接注入) 既存分岐の直前の無言 elif で red になる"
  fi
else
  bad "陰性(隣接注入) 注入位置が見つからない — 反証不能"
fi
if inject_silent "$MUTCHK/tail.sh" '^  elif \[ -n "\$\{LANE_PATHS:-\}" \] && \[ -z "\$BREAKER_SH" \]; then'; then
  if silent_check "$MUTCHK/tail.sh" >/dev/null 2>&1; then
    bad "陰性(末尾注入) 無言 elif を末尾へ入れても緑 = 検査器が見ていない"
  else
    ok "陰性(末尾注入) 末尾の無言 elif で red になる"
  fi
else
  bad "陰性(末尾注入) 注入位置が見つからない — 反証不能"
fi
# 抽出漏れそのものを本数で押さえる。取りこぼしが起きたらここが落ちる。
python3 - "$HOOK" <<'PY' && ok "抽出本数が実際の elif/else 本数と一致する" || bad "抽出漏れがある"
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("# --- (1) #91 基点規律"):src.index("done <<")]
actual = len(re.findall(r"^  (?:elif|else)\b", body, re.M))
lines = body.splitlines()
seen, i = 0, 0
while i < len(lines):
    if re.match(r"^  (?:elif|else)\b", lines[i]):
        seen += 1; i += 1
        while i < len(lines) and not re.match(r"^  (?:elif|else|fi)\b", lines[i]):
            i += 1
    else:
        i += 1
assert seen == actual, "extracted %d of %d branches" % (seen, actual)
PY

echo
echo "=== 変異体: 条件を外すと同じシナリオが素通し／誤発火することの実測 ==="
MUT="$SB/mut"; mkdir -p "$MUT"
mutate() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, needle, repl, out = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if needle not in t:
    raise SystemExit(1)
open(out, "w", encoding="utf-8").write(t.replace(needle, repl, 1))
PY
}

# (1) コマンド位置判定を substring に替える -> 引用が誤発火する
if mutate "$HOOK" \
   'if i + 1 >= len(toks) or toks[i] != "worktree" or toks[i + 1] != "add":' \
   'if "worktree" not in seg or "add" not in seg:' "$MUT/substr.sh"; then
  # 判定は「deny したか」ではなく「ゲートに入ったか」。位置判定を外すと
  # コミットメッセージがゲートへ入り、起点省略の警告が出る。
  run_gate "$HOOK" 'git commit -m "add worktree add support"' LANE_BASE=trunk HOME="$HOME"
  orig_err="$(cat "$SB/err")"
  run_gate "$MUT/substr.sh" 'git commit -m "add worktree add support"' LANE_BASE=trunk HOME="$HOME"
  mut_err="$(cat "$SB/err")"
  # 判定は「ゲートに入ったか」。入れば起点未指定か依存不在のいずれかを必ず告げる
  # （無言経路ゼロを上で機械照合済み）ので、出力の有無そのものが指標になる。
  if [ -z "$orig_err" ] && printf '%s' "$mut_err" | grep -q "lane-launch-gate"; then
    ok "変異(substring 判定) コミットメッセージがゲートへ入る = 位置判定は効いていた"
  else
    bad "変異(substring 判定) 挙動が変わらない (orig='${orig_err:0:40}' mut='${mut_err:0:40}')"
  fi
else
  bad "変異(substring 判定) 対象が見つからない — 反証不能"
fi

# (2) 基点判定の結果を握り潰す -> 古い起点が素通し
if mutate "$HOOK" '    brc=$?' '    brc=0' "$MUT/nobase.sh"; then
  if run_gate "$MUT/nobase.sh" "git -C $REPO worktree add $REPO/.worktrees/a/m -b feat/m $FRESH" LANE_BASE=trunk HOME="$HOME"; then
    ok "変異(基点判定除去) 古い起点が素通しする = 判定は効いていた"
  else
    bad "変異(基点判定除去) それでも block = case2 は別条件が出している"
  fi
else
  bad "変異(基点判定除去) 対象が見つからない — 反証不能"
fi

# (3) #88 の判定結果を握り潰す -> N=3 が素通し
if [ -n "$BREAKER" ] && mutate "$HOOK" '        crc=$?' '        crc=0' "$MUT/nobreak.sh"; then
  seed_repairs 3
  if run_gate "$MUT/nobreak.sh" "git -C $REPO worktree add $REPO/.worktrees/a/m2 -b feat/m2 origin/trunk" \
      LANE_BASE=trunk HOME="$HOME" LANE_PATHS="infra/main.tf" \
      LANE_BREAKER_SH="$BREAKER" LANE_REPAIR_LEDGER="$RLED"; then
    ok "変異(#88 判定除去) N=3 が素通しする = breaker 呼び出しは効いていた"
  else
    bad "変異(#88 判定除去) それでも block = case6 は別条件が出している"
  fi
else
  echo "SKIP: #88 変異体（breaker 不在）"
fi

echo
echo "=== 再実装していないことの機械照合（#88 の判定は breaker が正本） ==="
python3 - "$HOOK" <<'PY' && ok "hook は N=3 の閾値ロジックを自前で持たない（breaker を呼ぶだけ）" || bad "hook 側に閾値ロジックが混入している"
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
# 閾値の数値比較を hook 内で行っていないこと
assert not re.search(r"repairs?\s*>=\s*3|>=\s*threshold|threshold\s*=\s*3", t), "threshold logic inlined"
assert "repair-loop-breaker.sh" in t, "breaker not referenced"
assert "evaluate --ledger" in t, "breaker evaluate not invoked"
PY

echo
echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
