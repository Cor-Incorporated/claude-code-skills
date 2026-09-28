#!/usr/bin/env bash
# scripts/repo-janitor.sh deletes only what entered the base branch 7 or more days ago
# (rules/git-workflow.md「機械掃除は マージ済み + 7 日 限定」), never lists origin/HEAD as a
# branch, deletes remote branches before local ones so that git branch -d is not refused by an
# upstream it is ahead of, reports each refusal with git's reason, and stops when it cannot cd.
# Everything runs in throwaway repositories under mktemp with gh stubbed; --apply runs only there.
# The test also writes mutants of the janitor and runs itself against each one
# (JANITOR_UNDER_TEST) to show that the check pinning that behavior fails without it.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/tests/$(basename "$0")"
SRC="$ROOT/scripts/repo-janitor.sh"
JANITOR="${JANITOR_UNDER_TEST:-$SRC}"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
pass=0
fail=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$desc"
    fail=$((fail + 1))
  fi
}

# Keep git away from the user's config and hooks, including the janitor's own git calls.
export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.com
git config --global core.hooksPath /dev/null
git config --global commit.gpgsign false
git config --global init.defaultBranch develop

# gh stub: `gh pr list ... --head <branch> ...` prints OPEN for the branches in FAKE_GH_OPEN.
mkdir -p "$SB/bin"
cat >"$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  [ "$1" = --head ] && head="${2:-}"
  shift
done
for b in ${FAKE_GH_OPEN:-}; do
  [ "$b" = "$head" ] && { echo OPEN; exit 0; }
done
exit 0
EOF
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" FAKE_GH_OPEN=open-pr

# at <days ago> <git args...>: run git with the author and committer dates <days> ago
at() {
  local when
  when=$(($(date +%s) - $1 * 86400))
  shift
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" git "$@"
}

R="$SB/repo"
O="$SB/origin.git"
# feature <name> <days ago>: a branch with one commit on top of develop
feature() {
  git -C "$R" checkout -q -b "$1" develop
  at "$2" -C "$R" commit -q --allow-empty -m "$1"
  git -C "$R" checkout -q develop
}
# merge <name> <days ago>: merge the branch into develop with a merge commit
merge() {
  at "$2" -C "$R" merge -q --no-ff -m "merge $1" "$1"
}
# has <repo> <branch...>: every branch exists / lacks <repo> <branch...>: none of them exists
has() {
  local dir="$1" b
  shift
  for b in "$@"; do git -C "$dir" show-ref --verify --quiet "refs/heads/$b" || return 1; done
}
lacks() {
  local dir="$1" b
  shift
  for b in "$@"; do ! git -C "$dir" show-ref --verify --quiet "refs/heads/$b" || return 1; done
}
not_matching() { # <extended regex> <text>
  ! grep -qE -- "$1" <<<"$2"
}

git init -q --bare "$O"
git clone -q "$O" "$R" 2>/dev/null
at 30 -C "$R" commit -q --allow-empty -m init
git -C "$R" push -q origin develop
git -C "$R" remote set-head origin develop

feature old-merged 13
merge old-merged 12
# ahead: origin/ahead stays one commit behind the local branch that was merged
git -C "$R" checkout -q -b ahead develop
at 15 -C "$R" commit -q --allow-empty -m ahead-1
git -C "$R" push -q -u origin ahead
at 14 -C "$R" commit -q --allow-empty -m ahead-2
git -C "$R" checkout -q develop
merge ahead 11
feature wt-old-br 13
merge wt-old-br 11
feature open-pr 12
merge open-pr 10
# ff-old: a develop commit from 10 days ago, directly followed by a merge from 1 day ago
at 10 -C "$R" commit -q --allow-empty -m direct
git -C "$R" branch ff-old
feature new-merged 2
merge new-merged 1
feature wt-new-br 2
merge wt-new-br 1
git -C "$R" push -q origin develop old-merged open-pr ff-old new-merged
git -C "$R" worktree add -q "$R/.worktrees/claude/wt-old" wt-old-br
git -C "$R" worktree add -q "$R/.worktrees/claude/wt-new" wt-new-br
# lagging: merged into origin/develop from another clone, so the local HEAD does not contain it
git clone -q "$O" "$SB/other" 2>/dev/null
git -C "$SB/other" checkout -q -b lagging
at 13 -C "$SB/other" commit -q --allow-empty -m lagging
git -C "$SB/other" checkout -q develop
at 10 -C "$SB/other" merge -q --no-ff -m "merge lagging" lagging
git -C "$SB/other" push -q origin develop lagging
git -C "$R" fetch -q --prune origin
git -C "$R" branch -q --no-track lagging origin/lagging

snapshot() {
  git -C "$R" for-each-ref --format='%(refname) %(objectname)'
  git -C "$R" worktree list --porcelain
}
before=$(snapshot)
bash "$JANITOR" "$R" >"$SB/dry.log" 2>&1
rc=$?
check "dry-run exits 0" [ "$rc" -eq 0 ]
check "dry-run changes no ref and no worktree" [ "$before" = "$(snapshot)" ]
check "dry-run keeps the branch that entered develop 1 day ago" \
  grep -qE -- '- KEEP \(entered develop [0-9]{4}-[0-9]{2}-[0-9]{2}, < 7 days\): new-merged$' "$SB/dry.log"
check "dry-run keeps the remote branch that entered develop 1 day ago" \
  grep -qE -- '- KEEP \(entered develop [0-9-]{10}, < 7 days\): origin/new-merged$' "$SB/dry.log"
check "dry-run keeps the worktree whose branch entered develop 1 day ago" \
  grep -qE -- '- KEEP \(entered develop [0-9-]{10}, < 7 days\): .*/wt-new \[wt-new-br\]$' "$SB/dry.log"
check "dry-run lists the branch that entered develop 12 days ago" grep -qF -- '- 削除候補: old-merged（' "$SB/dry.log"
check "dry-run lists a branch whose tip is itself a develop commit from 10 days ago" \
  grep -qF -- '- 削除候補: ff-old（' "$SB/dry.log"
check "dry-run lists the merged worktree and its branch" \
  grep -qE -- '- 削除候補: .*/wt-old \[wt-old-br\]' "$SB/dry.log"
check "dry-run lists the branch of the worktree it removes" grep -qF -- '- 削除候補: wt-old-br（' "$SB/dry.log"
check "dry-run skips the remote branch with an open PR" grep -qF -- '- SKIP (open PRあり): origin/open-pr' "$SB/dry.log"
check "dry-run never lists origin/HEAD as a branch" not_matching 'origin/(origin|HEAD)' "$(cat "$SB/dry.log")"

bash "$JANITOR" "$R" --apply --remote >"$SB/apply.log" 2>&1
rc=$?
check "--apply exits 0" [ "$rc" -eq 0 ]
check "--apply removes the old worktree" [ ! -e "$R/.worktrees/claude/wt-old" ]
check "--apply keeps the new worktree" [ -d "$R/.worktrees/claude/wt-new" ]
check "--apply deletes the old local branches" lacks "$R" old-merged ff-old wt-old-br
check "--apply keeps the new local branches" has "$R" new-merged wt-new-br
check "--apply --remote deletes a local branch that was ahead of its upstream" lacks "$R" ahead
check "--apply deletes the old remote branches" lacks "$O" old-merged ff-old ahead lagging
check "--apply keeps the new remote branch" has "$O" new-merged
check "--apply keeps the remote branch with an open PR" has "$O" open-pr
check "--apply keeps develop" has "$R" develop
check "--apply keeps develop on the remote" has "$O" develop
check "--apply keeps a branch git refuses to delete" has "$R" lagging
check "--apply reports why git refused to delete a branch" \
  grep -qE -- "- FAILED \(-d拒否\): lagging — .*not fully merged" "$SB/apply.log"

# A path that cannot be entered must stop the janitor, not clean the current directory's repo.
out=$(cd "$R" && bash "$JANITOR" "$SB/no-such-dir" 2>&1)
rc=$?
check "a path it cannot enter stops the janitor" [ "$rc" -ne 0 ]
check "a path it cannot enter prints no plan" not_matching '^## Worktrees' "$out"

# Mutants: each removes one behavior; the check that pins it must fail.
# The old/new texts below are literal script source, so they must not expand.
# shellcheck disable=SC2016
if [ -z "${JANITOR_UNDER_TEST:-}" ]; then
  # caught_by <name> <expected FAIL line> <old text> <new text>
  caught_by() {
    local m="$SB/mutant-$1.sh" out
    if ! python3 - "$SRC" "$m" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit(f"expected one occurrence, found {text.count(old)}")
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
PY
    then
      check "mutant $1 can be written" false
      return
    fi
    out=$(JANITOR_UNDER_TEST="$m" bash "$SELF" 2>&1)
    check "mutant $1 is caught by: $2" grep -qF "FAIL: $2" <<<"$out"
  }
  caught_by no-age-filter "dry-run keeps the branch that entered develop 1 day ago" \
    $'MIN_AGE_DAYS=7\n' $'MIN_AGE_DAYS=0\n'
  caught_by next-commit-date "dry-run lists a branch whose tip is itself a develop commit from 10 days ago" \
    $'  git merge-base --is-ancestor "$1" "${FP[$lo]}" 2>/dev/null || return 0\n' \
    $'  [ $((lo + 1)) -lt ${#FP[@]} ] && lo=$((lo + 1))\n  git merge-base --is-ancestor "$1" "${FP[$lo]}" 2>/dev/null || return 0\n'
  caught_by origin-head-listed "dry-run never lists origin/HEAD as a branch" \
    $'  [ "$ref" = origin/HEAD ] && continue\n' ''
  caught_by local-before-remote "--apply --remote deletes a local branch that was ahead of its upstream" \
    'for step in worktrees remote local' 'for step in worktrees local remote'
  caught_by no-reason "--apply reports why git refused to delete a branch" \
    'echo "- FAILED (-d拒否): $br — $(reason "$err")"' 'echo "- FAILED (-d拒否): $br"'
  caught_by no-cd-guard "a path it cannot enter stops the janitor" \
    'cd "$REPO" || { echo "ERROR: $REPO へ移動できない" >&2; exit 1; }' 'cd "$REPO"'
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
