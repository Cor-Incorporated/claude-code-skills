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
codex_run "$ROOT/scripts/codex-parallel.sh" feat/replace >/dev/null
grep -q 'Worktree already exists' "$SB/run.log" && ok "C6 without CODEX_REPLACE_WORKTREE the wrapper still refuses" \
  || bad "C6 refuse" "$(tail -3 "$SB/run.log")"

CODEX_REPLACE_WORKTREE=1 FAKE_CODEX_FILE=second.txt codex_run "$ROOT/scripts/codex-parallel.sh" feat/replace >/dev/null
msg="$(git -C "$REPO" log -1 --format=%B feat/replace~0 -- first.txt 2>/dev/null)"
if has_first feat/replace && [[ "$msg" == "chore(wip): save uncommitted work on feat/replace"* && "$msg" == *"Agent-Lane: codex"* ]]; then
  ok "C6 the previous run's edits are a chore(wip) commit on feat/replace with Agent-Lane: codex"
else
  bad "C6 save" "first.txt on branch: $(has_first feat/replace && echo yes || echo no); message: ${msg:0:120}; $(grep -E 'Saved|Replacing|Could not' "$SB/run.log")"
fi

first_run "$ROOT/scripts/codex-parallel.sh" feat/discard
CODEX_REPLACE_WORKTREE=1 CODEX_REPLACE_SAVE_WIP=0 FAKE_CODEX_FILE=second.txt codex_run "$ROOT/scripts/codex-parallel.sh" feat/discard >/dev/null
! has_first feat/discard && grep -q 'CODEX_REPLACE_SAVE_WIP=0: discarding' "$SB/run.log" \
  && ok "C6 CODEX_REPLACE_SAVE_WIP=0 discards, and says so" || bad "C6 opt-out" "$(grep -E 'discard|Saved' "$SB/run.log")"

# Unsafe states are refused and keep the work (#472 review HIGH-1 / HIGH-2, M-3, M-4).
refused() {  # <branch> <label> — the replacement is refused and first.txt is still in the worktree
  CODEX_REPLACE_WORKTREE=1 FAKE_CODEX_FILE=second.txt codex_run "$ROOT/scripts/codex-parallel.sh" "$1" >/dev/null
  local wt="$REPO/.worktrees/codex/${1//\//-}"
  if grep -qi "not replacing" "$SB/run.log" && [[ -f "$wt/first.txt" ]]; then
    ok "C6 $2: refused, the work is still in the worktree"
  else
    bad "C6 $2" "$(grep -Ei 'not replacing|Saved|Replacing' "$SB/run.log" | head -3)"
  fi
}
first_run "$ROOT/scripts/codex-parallel.sh" feat/det
git -C "$REPO/.worktrees/codex/feat-det" checkout -q --detach
refused feat/det "a detached HEAD"

first_run "$ROOT/scripts/codex-parallel.sh" feat/merge
WT="$REPO/.worktrees/codex/feat-merge"
git -C "$WT" add first.txt && git -C "$WT" commit -q -m "chore: first" && echo mine >"$WT/README.md" && git -C "$WT" commit -qam "chore: mine"
git -C "$REPO" branch -q other develop && git -C "$REPO" worktree add -q "$SB/other" other && echo theirs >"$SB/other/README.md" \
  && git -C "$SB/other" commit -qam "chore: theirs" && git -C "$REPO" worktree remove "$SB/other"
git -C "$WT" merge -q other >/dev/null 2>&1
refused feat/merge "a merge stopped by a conflict"

first_run "$ROOT/scripts/codex-parallel.sh" feat/nogit
mv "$REPO/.worktrees/codex/feat-nogit/.git" "$SB/feat-nogit.git-link"
refused feat/nogit "a worktree whose .git link is gone (git -C would walk up to the main checkout)"
[[ -z "$(git -C "$REPO" log --oneline develop -1 --grep=wip)" ]] && ok "C6 the main checkout's develop got no wip commit" \
  || bad "C6 main checkout" "$(git -C "$REPO" log --oneline -2 develop)"

first_run "$ROOT/scripts/codex-parallel.sh" feat/secret
printf 'API_KEY=not-a-real-key\n' >"$REPO/.worktrees/codex/feat-secret/.env"
refused feat/secret "an untracked .env"

first_run "$ROOT/scripts/codex-parallel.sh" feat/devvars
printf 'CF_API_TOKEN=not-real\n' >"$REPO/.worktrees/codex/feat-devvars/.dev.vars"
refused feat/devvars "an untracked .dev.vars"

first_run "$ROOT/scripts/codex-parallel.sh" feat/hook
mkdir -p "$SB/hooks" && printf '#!/bin/sh\nexit 1\n' >"$SB/hooks/pre-commit" && chmod +x "$SB/hooks/pre-commit"
git -C "$REPO/.worktrees/codex/feat-hook" config core.hooksPath "$SB/hooks"
refused feat/hook "a commit hook that refuses the save"

# Mutant: the save block removed → the first run's edits are gone.
MUT="$SB/mut/codex-parallel.sh"
mkdir -p "$SB/mut/lib"
cp -R "$ROOT/scripts/lib/." "$SB/mut/lib/"
python3 - "$ROOT/scripts/codex-parallel.sh" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
needle = '    if [[ -n "$wt_status" ]]; then'
if needle not in text:
    raise SystemExit("mutation target not found")
pathlib.Path(dst).write_text(text.replace(needle, "    if false; then", 1))
PY
if [[ -f "$MUT" ]]; then
  first_run "$MUT" feat/mutant
  [[ -f "$REPO/.worktrees/codex/feat-mutant/first.txt" ]] || bad "C6 mutant setup" "the mutant did not run"
  CODEX_REPLACE_WORKTREE=1 FAKE_CODEX_FILE=second.txt codex_run "$MUT" feat/mutant >/dev/null
  ! has_first feat/mutant && grep -q "Replacing existing worktree" "$SB/run.log" \
    && ok "C6 mutant (no save) replaces and loses the previous run's edits; the real wrapper keeps them" \
    || bad "C6 mutant" "the mutant kept first.txt or did not replace — the test does not prove the save"
else
  bad "C6 mutant" "could not build the mutant"
fi

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
