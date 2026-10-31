#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/codex-parallel.sh
# C6 (2026-10-31): CODEX_REPLACE_WORKTREE=1 saves uncommitted work on the branch before `git worktree remove --force`.
#
# Origin: each L1 relaunch replaced the previous run's worktree; its uncommitted edits would have been deleted, and
# the orchestrator committed them by hand every time.
#
# Cases: without CODEX_REPLACE_WORKTREE the wrapper still refuses; with it, the edits of the previous run are a
# `wip(<branch>)` commit with `Agent-Lane: codex` on the branch; CODEX_REPLACE_SAVE_WIP=0 discards them; the mutant
# (the save removed) loses them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/codex-parallel-fixture.sh
. "$ROOT/tests/lib/codex-parallel-fixture.sh"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

codex_fixture_setup
export FAKE_CODEX_MODE=edit
first_run() {  # <script> <branch> — leave an uncommitted file in the branch's worktree
  FAKE_CODEX_FILE=first.txt FAKE_CODEX_CONTENT="first run's work" codex_run "$1" "$2" >/dev/null
}
has_first() {  # <branch> — is first.txt committed on the branch?
  git -C "$REPO" show "$1:first.txt" 2>/dev/null | grep -q "first run's work"
}

first_run "$ROOT/scripts/codex-parallel.sh" feat/replace
codex_run "$ROOT/scripts/codex-parallel.sh" feat/replace >/dev/null; rc_refuse=$?
grep -q 'Worktree already exists' "$SB/run.log" && ok "C6 without CODEX_REPLACE_WORKTREE the wrapper still refuses" \
  || bad "C6 refuse" "$(tail -3 "$SB/run.log")"

CODEX_REPLACE_WORKTREE=1 FAKE_CODEX_FILE=second.txt codex_run "$ROOT/scripts/codex-parallel.sh" feat/replace >/dev/null
msg="$(git -C "$REPO" log -1 --format=%B feat/replace~0 -- first.txt 2>/dev/null)"
if has_first feat/replace && [[ "$msg" == wip\(feat/replace\)* && "$msg" == *"Agent-Lane: codex"* ]]; then
  ok "C6 the previous run's edits are a wip(feat/replace) commit with Agent-Lane: codex"
else
  bad "C6 save" "first.txt on branch: $(has_first feat/replace && echo yes || echo no); message: ${msg:0:120}; $(grep -E 'Saved|Replacing|Could not' "$SB/run.log")"
fi

first_run "$ROOT/scripts/codex-parallel.sh" feat/discard
CODEX_REPLACE_WORKTREE=1 CODEX_REPLACE_SAVE_WIP=0 FAKE_CODEX_FILE=second.txt codex_run "$ROOT/scripts/codex-parallel.sh" feat/discard >/dev/null
! has_first feat/discard && grep -q 'CODEX_REPLACE_SAVE_WIP=0: discarding' "$SB/run.log" \
  && ok "C6 CODEX_REPLACE_SAVE_WIP=0 discards, and says so" || bad "C6 opt-out" "$(grep -E 'discard|Saved' "$SB/run.log")"

# Mutant: the save block removed → the first run's edits are gone.
MUT="$SB/mut/codex-parallel.sh"
mkdir -p "$SB/mut/lib"
cp -R "$ROOT/scripts/lib/." "$SB/mut/lib/"
python3 - "$ROOT/scripts/codex-parallel.sh" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = 'if [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]]; then'
if needle not in text:
    raise SystemExit("mutation target not found")
pathlib.Path(dst).write_text(text.replace(needle, "if false; then", 1))
PY
first_run "$MUT" feat/mutant
CODEX_REPLACE_WORKTREE=1 FAKE_CODEX_FILE=second.txt codex_run "$MUT" feat/mutant >/dev/null
! has_first feat/mutant && ok "C6 mutant (no save) loses the previous run's edits; the real wrapper keeps them" \
  || bad "C6 mutant" "the mutant kept first.txt — the test does not prove the save"

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
