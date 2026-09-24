#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/enforce-hook-deploy-integrity.sh
# scripts/lib の配備ドリフト検出（Phase 2b）と、その被覆を setup.sh の配備集合と結ぶ pair19。
#
# 起点 (2026-09-24): 配備済みの ~/.claude/scripts/lib/h1-runtime.sh（sha256 a6d1aca3…、
# draft PR #392 の wrapper）が develop の scripts/lib/h1-runtime.sh（918e1103…）と
# 食い違っていたのに、SessionStart の整合性検査は何も言わなかった。検査は hooks/** しか
# 比べておらず、setup.sh step 6 の `cp -R "$REPO_DIR"/scripts/lib/. "$SCRIPTS_DIR/lib/"`
# が配備するものを一度も見ていなかった。PR #392 の H5-PAIR
# （hooks/codex/h1-stall-runtime.sh ↔ scripts/lib/h1-runtime.sh）は片側しか監視されていなかった。
#
# 反証軸:
#   F2   起点入力（配備された wrapper だけが違う）で MD5 MISMATCH を出し、repo と deployed の
#        両方の値と配備先を挙げる
#   F2'  一致している配備では scripts/lib について何も言わない（雑音を作らない）
#   F2'' 未配備は NOT INSTALLED。*.sh 以外（yaml）と下位ディレクトリも cp -R と同じく数える
#   T2   検出のみ: 配備先も repo も書き換えない（loop-break T2 と同じ意味論）
#   F3   片側変異（Phase 2b の比較を落とす）で F2 が反転する
#   L    pair19（setup.sh の配備集合 ↔ 検査の被覆）が、どちらの片側変異でも red になり、
#        両側の値を挙げる
#
# **実 HOME・実配備には触らない。** すべて $WORK の中で閉じる。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/enforce-hook-deploy-integrity.sh"
LINK="$ROOT/tests/test-pairs-link.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"      # 検査対象の repo（hooks/ の sentinel + scripts/lib）
SBH="$WORK/home"       # 空の HOME。配備先はこの中にだけ作る
DEPLOYED_LIB="$SBH/.claude/scripts/lib"

# hook の compute_md5 と同じ選び方（macOS md5 / Linux md5sum）
md5_of() {
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | awk '{print $1}'; fi
}

# 節ごとに作り直して、前の節の配備状態を持ち越さない。
reset_fixture() {
  rm -rf "$PROJ" "$SBH"
  mkdir -p "$PROJ/hooks" "$PROJ/scripts/lib" "$SBH/.claude/hooks"
  # hooks dir として採用される条件（sentinel）。配備側にも同じものを置き、hooks/ 側の差分を 0 にする。
  printf '#!/bin/bash\n# sentinel\n' > "$PROJ/hooks/git-push-guard.sh"
  cp "$PROJ/hooks/git-push-guard.sh" "$SBH/.claude/hooks/git-push-guard.sh"
  # repo 側は起点事故の当事者（develop の実物）をそのまま使う。
  cp "$ROOT/scripts/lib/h1-runtime.sh" "$PROJ/scripts/lib/h1-runtime.sh"
}

# setup.sh step 6 と同じ形で配備する（sandbox の中だけ）。
deploy_lib() {
  mkdir -p "$DEPLOYED_LIB"
  cp -R "$PROJ/scripts/lib/." "$DEPLOYED_LIB/"
}

# hook を走らせる。stdout / stderr / rc を分けて取る。
# 本スクリプトは errexit を使わない。非ゼロは代入で拾う。
run_hook() { # $1=hook script
  LAST_OUT="$(
    env HOME="$SBH" CLAUDE_PROJECT_DIR="$PROJ" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 AIDD_LEDGER_SOURCE=test \
      bash "$1" 2>"$WORK/stderr"
  )"
  LAST_RC=$?
  LAST_ERR="$(cat "$WORK/stderr")"
}

# SessionStart の additionalContext（モデルの文脈へ届く側）を取り出す。
context_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
print(json.loads(raw)["hookSpecificOutput"]["additionalContext"] if raw.strip() else "")
'
}

echo "=== F2' 一致している配備では何も言わない（雑音を作らない） ==="
reset_fixture
deploy_lib
run_hook "$HOOK"
if [[ "$LAST_RC" -eq 0 && -z "$LAST_OUT" && "$LAST_ERR" != *"scripts/lib/"* ]]; then
  ok "配備が一致していれば issue 0（stdout 空・scripts/lib の言及なし）"
else
  bad "一致しているのに何か言った = 雑音、または fixture が壊れている" "rc=${LAST_RC} stdout=${LAST_OUT} stderr=${LAST_ERR}"
fi

echo ""
echo "=== F2 起点入力: 配備 wrapper だけが develop と違う（2026-09-24） ==="
reset_fixture
deploy_lib
printf '\n# drift: deployed from another branch (draft PR #392 preview)\n' >> "$DEPLOYED_LIB/h1-runtime.sh"
want_repo="$(md5_of "$PROJ/scripts/lib/h1-runtime.sh")"
want_dep="$(md5_of "$DEPLOYED_LIB/h1-runtime.sh")"
want="MD5 MISMATCH: scripts/lib/h1-runtime.sh (repo=${want_repo} deployed=${want_dep} target=${DEPLOYED_LIB}/h1-runtime.sh; no auto-sync)"
LEDGER="$SBH/.claude/hooks/ledger/guard-ledger.jsonl"
rm -f "$LEDGER"
run_hook "$HOOK"
if [[ "$LAST_ERR" == *"$want"* ]]; then
  ok "stderr: repo / deployed の両方の MD5 と配備先を挙げて報告する"
else
  bad "stderr で報告しない（起点事故そのもの）" "want: ${want} | got: ${LAST_ERR}"
fi
ctx="$(context_of "$LAST_OUT" 2>&1)"
if [[ "$ctx" == *"$want"* ]]; then
  ok "additionalContext にも同じ 1 行が入る（SessionStart の文脈へ届く）"
else
  bad "additionalContext に届かない" "got: ${ctx}"
fi
if [[ "$LAST_RC" -eq 0 ]]; then
  ok "exit 0（SessionStart は block しない）"
else
  bad "exit ${LAST_RC}（SessionStart の hook は常に 0 のはず）"
fi

echo ""
echo "=== T2 検出のみ: 配備先も repo も書き換えない ==="
after_repo="$(md5_of "$PROJ/scripts/lib/h1-runtime.sh")"
after_dep="$(md5_of "$DEPLOYED_LIB/h1-runtime.sh")"
if [[ "$after_repo" == "$want_repo" && "$after_dep" == "$want_dep" ]]; then
  ok "配備先は差分を保ったまま（auto-sync しない）"
else
  bad "どちらかが書き換えられた" "repo ${want_repo}->${after_repo} deployed ${want_dep}->${after_dep}"
fi

echo ""
echo "=== 台帳: 発火が guard-ledger.jsonl へ届く（ADR-006 要件 4） ==="
if grep -q '"rule":"scripts-lib-deploy-drift"' "$LEDGER" 2>/dev/null \
   && grep '"rule":"scripts-lib-deploy-drift"' "$LEDGER" | grep -q 'scripts/lib/h1-runtime.sh'; then
  ok "rule=scripts-lib-deploy-drift の行が差分ファイル名つきで追記される"
else
  bad "台帳に scripts-lib-deploy-drift の行が無い" "$(cat "$LEDGER" 2>/dev/null)"
fi
if grep -q '"rule":"hook-deploy-integrity".*"cmd_head":"issues=1"' "$LEDGER" 2>/dev/null; then
  ok "集計行 issues=1（差分は wrapper の 1 件だけ = 他に雑音なし）"
else
  bad "集計行が issues=1 でない" "$(grep '"rule":"hook-deploy-integrity"' "$LEDGER" 2>/dev/null)"
fi

echo ""
echo "=== F2'' 未配備: *.sh 以外と下位ディレクトリも cp -R と同じく数える ==="
reset_fixture
printf 'fixture: true\n' > "$PROJ/scripts/lib/fixture-map.yaml"
mkdir -p "$PROJ/scripts/lib/sub"
printf '#!/bin/bash\n# nested\n' > "$PROJ/scripts/lib/sub/nested.sh"
deploy_lib
rm "$DEPLOYED_LIB/fixture-map.yaml" "$DEPLOYED_LIB/sub/nested.sh"
run_hook "$HOOK"
for rel in fixture-map.yaml sub/nested.sh; do
  want="NOT INSTALLED: scripts/lib/${rel} (target=${DEPLOYED_LIB}/${rel}; detect-only"
  if [[ "$LAST_ERR" == *"$want"* ]]; then
    ok "未配備の scripts/lib/${rel} を配備先つきで名指しする"
  else
    bad "未配備の scripts/lib/${rel} を名指ししない" "want: ${want} | got: ${LAST_ERR}"
  fi
done
if [[ "$LAST_ERR" != *"scripts/lib/h1-runtime.sh"* ]]; then
  ok "一致している h1-runtime.sh は名指ししない"
else
  bad "一致しているファイルまで名指しした" "$LAST_ERR"
fi

echo ""
echo "=== F3 片側変異: Phase 2b の比較を落とすと F2 が反転する ==="
reset_fixture
deploy_lib
printf '\n# drift\n' >> "$DEPLOYED_LIB/h1-runtime.sh"
MUT="$WORK/mutant-integrity.sh"
if python3 - "$HOOK" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = 'if ! check_deployed_copy "$lib_label" "$filepath" "${INSTALLED_SCRIPTS_LIB_DIR}/${rel_path}"; then'
if t.count(old) != 1:
    sys.exit(f"mutation target found {t.count(old)} times (want 1)")
pathlib.Path(dst).write_text(t.replace(old, "if ! true; then  # mutant: scripts/lib is never compared", 1), encoding="utf-8")
PY
then
  run_hook "$MUT"
  if [[ "$LAST_ERR" != *"scripts/lib/h1-runtime.sh"* ]]; then
    ok "変異体は起点入力を見逃す = Phase 2b の比較が結論を作っている"
  else
    bad "変異体でも検出した = この節は比較を証明していない" "$LAST_ERR"
  fi
else
  bad "変異を注入できない — 注入側（変異対象の行）を直す。テストを緩めない"
fi

echo ""
echo "=== L pair19: setup.sh の配備集合 ↔ 検査の被覆（片側変異で red・両側の値を挙げる） ==="
# test-pairs-link.sh を空の HOME で走らせ、pair19 の行だけを見る。
# 空の HOME では machine-local の pair は skip になり、pair19 は repo のファイルと
# sandbox だけで照合する（CI と同じ条件）。
LINK_HOME="$WORK/linkhome"
mkdir -p "$LINK_HOME"
pair19() { # $1=setup.sh $2=integrity hook -> pair19 の判定行（FAIL なら次の詳細行も）
  env HOME="$LINK_HOME" AIDD_SETUP_SH="$1" AIDD_INTEGRITY_HOOK="$2" bash "$LINK" 2>&1 \
    | awk '/^(PASS|SKIP|FAIL): pair19/ { print; if ($1 == "FAIL:") { getline; print } }'
}

green="$(pair19 "$ROOT/setup.sh" "$HOOK")"
if [[ "$green" == "PASS: pair19"* ]]; then
  ok "実物どうしは一致する :: ${green}"
else
  bad "実物どうしで pair19 が PASS しない" "$green"
fi

# 宣言側（setup.sh）の片側変異: *.sh だけを配備する形に変える
SETUP_MUT="$WORK/setup-glob.sh"
if python3 - "$ROOT/setup.sh" "$SETUP_MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = 'cp -R "$REPO_DIR"/scripts/lib/. "$SCRIPTS_DIR/lib/"'
if t.count(old) != 1:
    sys.exit(f"mutation target found {t.count(old)} times (want 1)")
pathlib.Path(dst).write_text(t.replace(old, 'cp "$REPO_DIR"/scripts/lib/*.sh "$SCRIPTS_DIR/lib/"', 1), encoding="utf-8")
PY
then
  red="$(pair19 "$SETUP_MUT" "$HOOK")"
  if [[ "$red" == "FAIL: pair19"* && "$red" == *"declaration(setup.sh)="* && "$red" == *"enforcement("* ]]; then
    ok "setup.sh だけ変えると red・両側を挙げる"
  else
    bad "setup.sh の片側変異で red にならない、または片側しか挙げない" "$red"
  fi
else
  bad "setup.sh へ変異を注入できない — 注入側を直す"
fi

# 宣言側（setup.sh）の片側変異: 配備先を変える
SETUP_DEST="$WORK/setup-dest.sh"
if python3 - "$ROOT/setup.sh" "$SETUP_DEST" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = 'SCRIPTS_DIR="$HOME/.claude/scripts"'
if t.count(old) != 1:
    sys.exit(f"mutation target found {t.count(old)} times (want 1)")
pathlib.Path(dst).write_text(t.replace(old, 'SCRIPTS_DIR="$HOME/.local/share/claude-scripts"', 1), encoding="utf-8")
PY
then
  red="$(pair19 "$SETUP_DEST" "$HOOK")"
  if [[ "$red" == "FAIL: pair19"* && "$red" == *".local/share/claude-scripts/lib/h1-runtime.sh"* && "$red" == *".claude/scripts/lib/h1-runtime.sh"* ]]; then
    ok "配備先だけ変えると red・両側の配備先を挙げる"
  else
    bad "配備先の片側変異で red にならない、または配備先を挙げない" "$red"
  fi
else
  bad "setup.sh（配備先）へ変異を注入できない — 注入側を直す"
fi

# 強制側（検査 hook）の片側変異: *.sh しか比べない形に変える
HOOK_MUT="$WORK/integrity-shonly.sh"
if python3 - "$HOOK" "$HOOK_MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
t = pathlib.Path(src).read_text(encoding="utf-8")
old = 'find "$PROJECT_SCRIPTS_LIB_DIR" -type f -print0'
if t.count(old) != 1:
    sys.exit(f"mutation target found {t.count(old)} times (want 1)")
pathlib.Path(dst).write_text(t.replace(old, 'find "$PROJECT_SCRIPTS_LIB_DIR" -type f -name "*.sh" -print0', 1), encoding="utf-8")
PY
then
  red="$(pair19 "$ROOT/setup.sh" "$HOOK_MUT")"
  if [[ "$red" == "FAIL: pair19"* && "$red" == *"gh-permission-map.yaml"* && "$red" == *"enforcement("* ]]; then
    ok "検査 hook だけ変えると red・落ちたファイルを挙げる"
  else
    bad "検査 hook の片側変異で red にならない" "$red"
  fi
else
  bad "検査 hook へ変異を注入できない — 注入側を直す"
fi

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
