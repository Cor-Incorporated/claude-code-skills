#!/usr/bin/env bash
# scripts/repo-janitor.sh deletes only what entered the base branch 7 or more days ago
# (rules/git-workflow.md「機械掃除は マージ済み + 7 日 限定」) and, for worktrees and branches with no
# commits of their own, only what was created and first seen in the base 7 or more days ago. It never
# lists origin/HEAD, never touches protected branches (local, remote, or checked out in a worktree), the
# worktree it runs from or was given, a branch checked out in a kept worktree (nor its remote branch),
# a worktree with changes git status hides (untracked files under status.showUntrackedFiles=no,
# assume-unchanged or skip-worktree edits, content a lossy clean filter hides, submodule edits that
# submodule.<name>.ignore hides), a locked worktree, a worktree holding ignored files that the handover
# criteria do not list as regenerable (also when they appear between the plan and the removal), or a
# remote branch whose open PRs (in origin or any fork ancestor, as head or as base of a stacked PR) gh
# cannot rule out, including when origin is not a GitHub URL. It plans from the worktree list taken
# before pruning, so --apply deletes nothing the dry-run showed as kept; it resolves the base as
# refs/remotes/..., prunes the admin data of a vanished worktree only after MIN_AGE_DAYS, picks the
# base after fetching, keeps remote branches when fetch fails, passes -R owner/repo to gh, deletes
# remote branches before local ones (so git branch -d is not refused by an upstream it is ahead of),
# re-checks right before each remote delete that no worktree still has the branch checked out, deletes
# exactly refs/heads/<branch> (never a tag of the same name) under --force-with-lease, reports refusals
# with git's reason, and stops when it cannot cd.
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
SB=$(cd "$SB" && pwd -P)
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
export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
git config --global user.name test
git config --global user.email test@example.com
git config --global core.hooksPath /dev/null
git config --global commit.gpgsign false
git config --global init.defaultBranch develop
git config --global advice.detachedHead false

# gh stub. `gh repo view <repo> ...` prints the parent that FAKE_GH_PARENTS maps <repo> to
# (<repo>=<parent> pairs; nothing if unmapped) and fails when FAKE_GH_PARENT_FAIL is set.
# `gh pr list [-R <repo>] --head <branch> --state open --json number -q length` prints 1 for branches
# in FAKE_GH_OPEN or <repo>:<branch> pairs in FAKE_GH_OPEN_AT, else 0, and fails for branches in
# FAKE_GH_FAIL. `gh pr list ... --base <branch> ...` prints 1 for branches in FAKE_GH_BASE_OPEN or
# <repo>:<branch> pairs in FAKE_GH_BASE_OPEN_AT, else 0, and fails for branches in FAKE_GH_BASE_FAIL.
# The first `gh pr list` call creates FAKE_GH_TOUCH when that is set (a file that appears while the
# janitor is still planning). Every call appends its arguments to GH_LOG when that is set.
mkdir -p "$SB/bin"
cat >"$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = repo ] && [ "${2:-}" = view ]; then
  [ -n "${FAKE_GH_PARENT_FAIL:-}" ] && exit 1
  for pair in ${FAKE_GH_PARENTS:-}; do
    [ "${pair%%=*}" = "${3:-}" ] && { printf '%s\n' "${pair#*=}"; exit 0; }
  done
  printf '\n'
  exit 0
fi
if [ -n "${FAKE_GH_TOUCH:-}" ] && [ ! -e "$FAKE_GH_TOUCH" ]; then
  printf 'appeared during planning\n' >"$FAKE_GH_TOUCH"
fi
head=""
base=""
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="${2:-}" ;;
    --base) base="${2:-}" ;;
    -R) repo="${2:-}" ;;
  esac
  shift
done
if [ -n "$base" ]; then
  for b in ${FAKE_GH_BASE_FAIL:-}; do [ "$b" = "$base" ] && exit 1; done
  for b in ${FAKE_GH_BASE_OPEN:-}; do [ "$b" = "$base" ] && { echo 1; exit 0; }; done
  for b in ${FAKE_GH_BASE_OPEN_AT:-}; do [ "$b" = "$repo:$base" ] && { echo 1; exit 0; }; done
  echo 0
  exit 0
fi
for b in ${FAKE_GH_FAIL:-}; do [ "$b" = "$head" ] && exit 1; done
for b in ${FAKE_GH_OPEN:-}; do [ "$b" = "$head" ] && { echo 1; exit 0; }; done
for b in ${FAKE_GH_OPEN_AT:-}; do [ "$b" = "$repo:$head" ] && { echo 1; exit 0; }; done
echo 0
EOF
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" FAKE_GH_OPEN=open-pr FAKE_GH_FAIL=gh-down \
  FAKE_GH_BASE_OPEN=stackbase FAKE_GH_BASE_FAIL=stackfail

# at <days ago> <git args...>: run git with the author, committer (and so reflog) dates <days> ago
at() {
  local when
  when=$(($(date +%s) - $1 * 86400))
  shift
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" git "$@"
}

R="$SB/repo"
O="$SB/origin.git"
W="$R/.worktrees/claude"
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
matching() { # <extended regex> <file>
  grep -qE -- "$1" "$2"
}
not_matching() { # <extended regex> <text>
  ! grep -qE -- "$1" <<<"$2"
}

git init -q --bare "$O"
git clone -q "$O" "$R" 2>/dev/null
# The janitor asks gh about PRs only for a GitHub origin, so origin looks like one and insteadOf points
# it at the local bare repository (fetch and push stay offline).
git -C "$R" config url."$O".insteadOf https://github.com/acme/main.git
git -C "$R" remote set-url origin https://github.com/acme/main.git
printf '*.log\n__pycache__/\n' >"$R/.gitignore"
git -C "$R" add .gitignore
at 30 -C "$R" commit -q -m init
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
for b in wt-old-br dirty-br self-br resume-br log-br gh-down stackbase stackfail gone-new-br gone-old-br \
  lk-br tw-br race-br; do
  feature "$b" 13
  merge "$b" 11
done
feature mainlike 14
merge mainlike 13
# protected local branches: master is free, stg gets a worktree below. (Not main: a worktree on main
# would keep origin/main through the kept-worktree rule and hide the remote protected-branch check.)
git -C "$R" branch master mainlike
git -C "$R" branch stg mainlike
feature open-pr 12
merge open-pr 10
# ff-old: a develop commit from 10 days ago (created, and pushed to origin/develop, then),
# directly followed by a merge from 1 day ago
at 10 -C "$R" commit -q --allow-empty -m direct
at 10 -C "$R" branch ff-old
at 10 -C "$R" push -q origin develop
feature new-merged 2
merge new-merged 1
feature wt-new-br 2
merge wt-new-br 1
# ffnew: an old commit on an old branch, fast-forwarded into develop and pushed today
at 15 -C "$R" checkout -q -b ffnew develop
at 15 -C "$R" commit -q --allow-empty -m ffnew
git -C "$R" checkout -q develop
git -C "$R" merge -q --ff-only ffnew
# ffremote: the same, but the branch was pushed to origin 15 days ago
at 15 -C "$R" checkout -q -b ffremote develop
at 15 -C "$R" commit -q --allow-empty -m ffremote
git -C "$R" checkout -q develop
git -C "$R" merge -q --ff-only ffremote
at 15 -C "$R" push -q origin ffremote
# ffwt-br: the same again, for a worktree below (a separate branch, so that worktree does not also keep
# ffnew and hide the local fast-forward check)
at 15 -C "$R" checkout -q -b ffwt-br develop
at 15 -C "$R" commit -q --allow-empty -m ffwt-br
git -C "$R" checkout -q develop
git -C "$R" merge -q --ff-only ffwt-br
git -C "$R" push -q origin develop old-merged open-pr new-merged gh-down dirty-br stackbase stackfail \
  wt-old-br gone-old-br lk-br tw-br race-br
git -C "$R" push -q origin mainlike:refs/heads/main
at 10 -C "$R" push -q origin ff-old
at 11 -C "$R" worktree add -q "$W/wt-old" wt-old-br
mkdir -p "$W/wt-old/__pycache__"
printf 'x' >"$W/wt-old/__pycache__/mod.cpython-311.pyc"
git -C "$R" worktree add -q "$W/wt-new" wt-new-br
at 11 -C "$R" worktree add -q "$W/dirty" dirty-br
printf 'work in progress\n' >"$W/dirty/notes.txt"
at 11 -C "$R" worktree add -q "$W/self" self-br
# an ignored raw log is evidence, not a regenerable artifact
at 11 -C "$R" worktree add -q "$W/logwt" log-br
printf 'raw evidence\n' >"$W/logwt/run.log"
# created today: a worktree on an old merged branch, and a worktree and a branch with no own commits
git -C "$R" worktree add -q "$W/resume" resume-br
git -C "$R" worktree add -q -b fresh "$W/fresh" ff-old
git -C "$R" branch fresh-br ff-old
# ... and pushed today, so its remote branch has no commits of its own and was first fetched today
git -C "$R" push -q origin fresh-br
# a worktree created 11 days ago that switched today to a new branch with no commits of its own
at 11 -C "$R" worktree add -q -b sw-base "$W/switched" ff-old
git -C "$W/switched" switch -q -c sw-new ff-old
# a worktree created 11 days ago on a branch fast-forwarded into develop today
at 11 -C "$R" worktree add -q "$W/ffwt" ffwt-br
# a locked worktree (on an external disk, say): git worktree remove refuses it, so the plan must not list it
at 11 -C "$R" worktree add -q "$W/lk" lk-br
git -C "$R" worktree lock --reason "external disk" "$W/lk"
# one branch checked out in two worktrees: the clean one can go, the dirty one stays with the branch
at 11 -C "$R" worktree add -q "$W/tw-clean" tw-br
at 11 -C "$R" worktree add -q -f "$W/tw-dirty" tw-br
printf 'draft\n' >"$W/tw-dirty/draft.txt"
# a clean worktree that gains an ignored raw log while the janitor is still planning (FAKE_GH_TOUCH)
at 11 -C "$R" worktree add -q "$W/race" race-br
# a worktree on a protected branch
at 11 -C "$R" worktree add -q "$W/wt-stg" stg
# worktrees whose directories vanished: gone-new was last used today, gone-old 10 days ago
git -C "$R" worktree add -q "$W/gone-new" gone-new-br
rm -rf "$W/gone-new"
git -C "$R" worktree add -q "$W/gone-old" gone-old-br
python3 -c 'import os, sys, time; t = time.time() - 10 * 86400; os.utime(sys.argv[1], (t, t))' \
  "$(git -C "$R" rev-parse --path-format=absolute --git-path worktrees/gone-old/index)"
rm -rf "$W/gone-old"
# a tag with the same name as a young branch points at an old merged commit
git -C "$R" tag new-merged old-merged
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
  matching '- KEEP \(entered develop [0-9]{4}-[0-9]{2}-[0-9]{2}, < 7 days\): new-merged$' "$SB/dry.log"
check "dry-run keeps the remote branch that entered develop 1 day ago" \
  matching '- KEEP \(entered develop [0-9-]{10}, < 7 days\): origin/new-merged$' "$SB/dry.log"
check "dry-run keeps the worktree whose branch entered develop 1 day ago" \
  matching '- KEEP \(entered develop [0-9-]{10}, < 7 days\): .*/wt-new \[wt-new-br\]$' "$SB/dry.log"
check "dry-run lists the branch that entered develop 12 days ago" matching '- 削除候補: old-merged（' "$SB/dry.log"
check "dry-run lists a branch whose tip is itself a develop commit from 10 days ago" \
  matching '- 削除候補: ff-old（' "$SB/dry.log"
check "dry-run keeps a branch fast-forwarded into develop today" \
  matching '- KEEP \(no own commits, first seen in origin/develop [0-9-]{10}, .*\): ffnew$' "$SB/dry.log"
check "dry-run lists the merged worktree and its branch" matching '- 削除候補: .*/wt-old \[wt-old-br\]' "$SB/dry.log"
check "dry-run lists the branch of the worktree it removes" matching '- 削除候補: wt-old-br（' "$SB/dry.log"
check "dry-run skips a worktree with an ignored file that is not regenerable" \
  matching '- SKIP \(ignore されたファイルがある: run\.log' "$SB/dry.log"
check "dry-run skips the remote branch with an open PR" matching '- SKIP \(open PRあり\): origin/open-pr' "$SB/dry.log"
check "dry-run skips a remote branch whose PRs cannot be checked" \
  matching '- SKIP \(open PR の有無を確かめられない\): origin/gh-down' "$SB/dry.log"
check "dry-run never lists origin/HEAD as a branch" not_matching 'origin/(origin|HEAD)' "$(cat "$SB/dry.log")"
check "dry-run does not list a branch checked out in a kept worktree" \
  not_matching '削除候補: dirty-br（' "$(cat "$SB/dry.log")"
check "dry-run keeps a worktree created today on an old merged branch" \
  matching '- KEEP \(worktree created [0-9-]{10}, .*\): .*/resume \[resume-br\]$' "$SB/dry.log"
check "dry-run keeps a branch created today with no commits of its own" \
  matching '- KEEP \(no own commits, created [0-9-]{10}, .*\): fresh-br$' "$SB/dry.log"
check "dry-run keeps a remote branch fast-forwarded into develop today" \
  matching '- KEEP \(no own commits, first seen in origin/develop [0-9-]{10}, .*\): origin/ffremote$' "$SB/dry.log"
check "dry-run keeps a remote branch pushed today at an old develop commit" \
  matching '- KEEP \(no own commits, first fetched [0-9-]{10}, .*\): origin/fresh-br$' "$SB/dry.log"
check "dry-run skips a remote branch that an open PR uses as its base" \
  matching '- SKIP \(このブランチを base にする open PR あり\): origin/stackbase$' "$SB/dry.log"
check "dry-run skips a remote branch whose stacked PRs cannot be checked" \
  matching '- SKIP \(このブランチを base にする open PR の有無を確かめられない\): origin/stackfail$' "$SB/dry.log"
check "dry-run skips the remote branch of a branch checked out in a kept worktree" \
  matching '- SKIP \(残す worktree で checkout 中\): origin/dirty-br$' "$SB/dry.log"
check "dry-run skips a worktree on a protected branch" matching '- SKIP \(protected\): .*/wt-stg \[stg\]$' "$SB/dry.log"
check "dry-run keeps a worktree switched today to a new branch with no commits of its own" \
  matching '- KEEP \(no own commits, branch created [0-9-]{10}, .*\): .*/switched \[sw-new\]$' "$SB/dry.log"
check "dry-run keeps a worktree whose branch was fast-forwarded into develop today" \
  matching '- KEEP \(no own commits, first seen in origin/develop [0-9-]{10}, .*\): .*/ffwt \[ffwt-br\]$' "$SB/dry.log"
check "dry-run shows the admin data it would prune for a worktree gone 10 days" \
  matching '- PRUNE 候補: Removing worktrees/gone-old: ' "$SB/dry.log"
check "dry-run does not plan to prune a worktree that vanished today" \
  not_matching 'PRUNE 候補: .*gone-new' "$(cat "$SB/dry.log")"
check "dry-run keeps the branch of the worktree it would prune (still checked out in this plan)" \
  matching '- SKIP \(checked out in worktree\): gone-old-br$' "$SB/dry.log"
check "dry-run skips a locked worktree" matching '- SKIP \(locked\): .*/lk \[lk-br\]$' "$SB/dry.log"
check "dry-run keeps the remote branch of a branch that a kept worktree also checks out" \
  matching '- SKIP \(残す worktree で checkout 中\): origin/tw-br$' "$SB/dry.log"
check "dry-run lists the clean worktree that --apply will find changed" \
  matching '- 削除候補: .*/race \[race-br\]' "$SB/dry.log"

out=$(bash "$JANITOR" "$W/self" 2>&1)
check "dry-run skips the worktree it was given" \
  grep -qE -- '- SKIP \(この実行が使っている worktree\): .*/self \[self-br\]$' <<<"$out"

# The caller's git environment must not redirect the janitor to another repository.
git init -q "$SB/elsewhere"
at 30 -C "$SB/elsewhere" commit -q --allow-empty -m elsewhere
out=$(GIT_DIR="$SB/elsewhere/.git" GIT_WORK_TREE="$SB/elsewhere" bash "$JANITOR" "$R" 2>&1)
check "the janitor ignores GIT_DIR inherited from the caller" grep -qF -- '- 削除候補: old-merged（' <<<"$out"

# The real run starts inside the self worktree, which must survive it. While it is still planning, the
# race worktree gains an ignored raw log (the gh stub writes it on the first PR query).
(cd "$W/self" && FAKE_GH_TOUCH="$W/race/run.log" bash "$JANITOR" "$R" --apply --remote) >"$SB/apply.log" 2>&1
rc=$?
check "--apply exits 0" [ "$rc" -eq 0 ]
check "--apply removes the old worktree (its only ignored files are regenerable)" [ ! -e "$W/wt-old" ]
check "--apply keeps the new worktree" [ -d "$W/wt-new" ]
check "--apply keeps the worktree it runs from" [ -d "$W/self" ]
check "--apply keeps a worktree created today on an old merged branch" [ -d "$W/resume" ]
check "--apply keeps a worktree created today with no commits of its own" [ -d "$W/fresh" ]
check "--apply keeps a worktree with an ignored file that is not regenerable" [ -f "$W/logwt/run.log" ]
check "--apply keeps the dirty worktree" [ -f "$W/dirty/notes.txt" ]
check "--apply deletes the old local branches" lacks "$R" old-merged ff-old wt-old-br mainlike
check "--apply keeps the new local branches" has "$R" new-merged wt-new-br
check "--apply keeps the branches of kept worktrees" has "$R" dirty-br self-br resume-br fresh log-br
check "--apply keeps a branch created today with no commits of its own" has "$R" fresh-br
check "--apply keeps a branch fast-forwarded into develop today" has "$R" ffnew
check "--apply --remote deletes a local branch that was ahead of its upstream" lacks "$R" ahead
check "--apply deletes the old remote branches" lacks "$O" old-merged ff-old ahead lagging
check "--apply keeps the new remote branch" has "$O" new-merged
check "--apply keeps the remote branch with an open PR" has "$O" open-pr
check "--apply keeps a remote branch whose PRs cannot be checked" has "$O" gh-down
check "--apply keeps origin/main" has "$O" main
check "--apply keeps develop" has "$R" develop
check "--apply keeps develop on the remote" has "$O" develop
check "--apply keeps a branch git refuses to delete" has "$R" lagging
check "--apply keeps a local protected branch (master)" has "$R" master
check "--apply keeps a worktree on a protected branch (stg)" [ -d "$W/wt-stg" ]
check "--apply --remote keeps a remote branch fast-forwarded into develop today" has "$O" ffremote
check "--apply --remote keeps a remote branch pushed today at an old develop commit" has "$O" fresh-br
check "--apply keeps a remote branch that an open PR uses as its base" has "$O" stackbase
check "--apply keeps a remote branch whose stacked PRs cannot be checked" has "$O" stackfail
check "--apply --remote keeps the remote branch of a branch checked out in a kept worktree" has "$O" dirty-br
check "--apply keeps a worktree switched today to a new branch with no commits of its own" [ -d "$W/switched" ]
check "--apply keeps a worktree whose branch was fast-forwarded into develop today" [ -d "$W/ffwt" ]
check "--apply keeps the admin data of a worktree whose directory vanished today" \
  grep -qxF "worktree $W/gone-new" <<<"$(git -C "$R" worktree list --porcelain)"
check "--apply keeps the branch of a worktree whose directory vanished today" has "$R" gone-new-br
check "--apply prunes the admin data of a worktree gone 10 days" \
  not_matching "^worktree $W/gone-old$" "$(git -C "$R" worktree list --porcelain)"
check "--apply reports what it pruned" matching '- PRUNED: Removing worktrees/gone-old: ' "$SB/apply.log"
check "--apply reports why git refused to delete a branch" \
  matching "- FAILED \(-d拒否\): lagging — .*not fully merged" "$SB/apply.log"
check "--apply keeps the branch of a worktree it pruned in this run (the approved dry-run kept it)" \
  has "$R" gone-old-br
check "--apply --remote keeps the remote branch of a worktree it pruned in this run" has "$O" gone-old-br
check "--apply --remote deletes the remote branch of a worktree it removes" lacks "$O" wt-old-br
check "--apply keeps a locked worktree" [ -d "$W/lk" ]
check "--apply --remote keeps the remote branch of a locked worktree" has "$O" lk-br
check "--apply removes the clean one of two worktrees on the same branch" [ ! -e "$W/tw-clean" ]
check "--apply keeps a branch that a kept worktree still checks out" has "$R" tw-br
check "--apply --remote keeps the remote branch that a kept worktree still checks out" has "$O" tw-br
check "--apply keeps a worktree that gained an ignored file after the plan" [ -f "$W/race/run.log" ]
check "--apply says why it kept the worktree it planned to remove" \
  matching '- SKIP \(計画の後に変わった: ignore されたファイル run\.log.*\): .*/race$' "$SB/apply.log"
check "--apply --remote keeps the remote branch of a worktree it did not remove after all" has "$O" race-br
check "--apply keeps the branch of a worktree it did not remove after all" has "$R" race-br

# --force-with-lease: fetch from a mirror taken before the branch moved, push to the real origin.
L="$SB/lease"
git init -q --bare "$L/origin.git"
git clone -q "$L/origin.git" "$L/repo" 2>/dev/null
at 30 -C "$L/repo" commit -q --allow-empty -m init
git -C "$L/repo" checkout -q -b mover
at 13 -C "$L/repo" commit -q --allow-empty -m mover
git -C "$L/repo" checkout -q develop
at 11 -C "$L/repo" merge -q --no-ff -m "merge mover" mover
git -C "$L/repo" push -q origin develop mover
git clone -q --bare "$L/origin.git" "$L/mirror.git"
git clone -q "$L/origin.git" "$L/pusher" 2>/dev/null
git -C "$L/pusher" checkout -q mover
git -C "$L/pusher" commit -q --allow-empty -m "pushed after the fetch"
git -C "$L/pusher" push -q origin mover
git -C "$L/repo" config url."$L/mirror.git".insteadOf https://github.com/acme/lease.git
git -C "$L/repo" config url."$L/origin.git".pushInsteadOf https://github.com/acme/lease.git
git -C "$L/repo" remote set-url origin https://github.com/acme/lease.git
bash "$JANITOR" "$L/repo" --apply --remote >"$SB/lease.log" 2>&1
check "--apply --remote keeps a remote branch that moved after the fetch" has "$L/origin.git" mover
check "--apply --remote reports the stale lease" matching '- FAILED: origin/mover — .*stale info' "$SB/lease.log"

# A failed fetch means the plan is stale: remote branches must be kept.
F="$SB/fetchfail"
git init -q --bare "$F/origin.git"
git clone -q "$F/origin.git" "$F/repo" 2>/dev/null
at 30 -C "$F/repo" commit -q --allow-empty -m init
git -C "$F/repo" checkout -q -b fb
at 13 -C "$F/repo" commit -q --allow-empty -m fb
git -C "$F/repo" checkout -q develop
at 11 -C "$F/repo" merge -q --no-ff -m "merge fb" fb
git -C "$F/repo" push -q origin develop fb
git -C "$F/repo" config url."$F/missing.git".insteadOf https://github.com/acme/fetchfail.git
git -C "$F/repo" config url."$F/origin.git".pushInsteadOf https://github.com/acme/fetchfail.git
git -C "$F/repo" remote set-url origin https://github.com/acme/fetchfail.git
bash "$JANITOR" "$F/repo" --apply --remote >"$SB/fetchfail.log" 2>&1
check "--apply --remote keeps remote branches when fetch fails" has "$F/origin.git" fb
check "--apply --remote says why it kept them" matching '- SKIP \(fetch に失敗したので消さない\): origin/fb' "$SB/fetchfail.log"

# The base branch is picked after fetching: develop created on origin since the last fetch counts.
N="$SB/newbase"
git init -q --bare "$N/origin.git"
git -C "$N/origin.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$N/seed"
at 30 -C "$N/seed" commit -q --allow-empty -m init
git -C "$N/seed" remote add origin "$N/origin.git"
git -C "$N/seed" push -q origin main
git clone -q "$N/origin.git" "$N/repo" 2>/dev/null
git -C "$N/seed" checkout -q -b develop
at 20 -C "$N/seed" commit -q --allow-empty -m develop
git -C "$N/seed" push -q origin develop
out=$(bash "$JANITOR" "$N/repo" 2>&1)
check "dry-run picks the base branch after fetching" grep -qF -- '基準ブランチ: origin/develop（' <<<"$out"

# gh gets -R owner/repo for a GitHub origin, and also looks at the fork's parent. The GitHub URLs
# are rewritten to a local origin with insteadOf, so fetch works offline.
G="$SB/ghrepo"
git init -q --bare "$G/origin.git"
git clone -q "$G/origin.git" "$G/repo" 2>/dev/null
at 30 -C "$G/repo" commit -q --allow-empty -m init
git -C "$G/repo" checkout -q -b oldbr
at 13 -C "$G/repo" commit -q --allow-empty -m oldbr
git -C "$G/repo" checkout -q develop
at 11 -C "$G/repo" merge -q --no-ff -m "merge oldbr" oldbr
git -C "$G/repo" push -q origin develop oldbr
git -C "$G/repo" config url."$G/origin.git".insteadOf https://github.com/acme/widgets.git
git -C "$G/repo" config --add url."$G/origin.git".insteadOf git@github.com:acme/widgets.git
git -C "$G/repo" remote set-url origin https://github.com/acme/widgets.git
GH_LOG="$SB/gh-https.log" bash "$JANITOR" "$G/repo" >/dev/null 2>&1
check "gh gets -R owner/repo for an https origin" grep -qF -- '-R acme/widgets' "$SB/gh-https.log"
git -C "$G/repo" remote set-url origin git@github.com:acme/widgets.git
GH_LOG="$SB/gh-scp.log" bash "$JANITOR" "$G/repo" >/dev/null 2>&1
check "gh gets -R owner/repo for an scp-style origin" grep -qF -- '-R acme/widgets' "$SB/gh-scp.log"
FAKE_GH_PARENTS=acme/widgets=acme/upstream FAKE_GH_OPEN_AT=acme/upstream:oldbr \
  bash "$JANITOR" "$G/repo" >"$SB/gh-fork.log" 2>&1
check "dry-run skips a branch with an open PR in the fork's parent" \
  matching '- SKIP \(open PRあり\): origin/oldbr' "$SB/gh-fork.log"
FAKE_GH_PARENT_FAIL=1 bash "$JANITOR" "$G/repo" >"$SB/gh-noparent.log" 2>&1
check "dry-run skips remote branches when the fork parent cannot be checked" \
  matching '- SKIP \(open PR の有無を確かめられない\): origin/oldbr' "$SB/gh-noparent.log"
# A fork of a fork: the PR can target the root, two levels up.
FAKE_GH_PARENTS="acme/widgets=acme/upstream acme/upstream=acme/root" FAKE_GH_OPEN_AT=acme/root:oldbr \
  bash "$JANITOR" "$G/repo" >"$SB/gh-forkfork.log" 2>&1
check "dry-run skips a branch with an open PR in the fork's grandparent" \
  matching '- SKIP \(open PRあり\): origin/oldbr' "$SB/gh-forkfork.log"
# The stacked-PR query must ask origin by name too (gh may otherwise ask the upstream remote).
FAKE_GH_BASE_OPEN_AT=acme/widgets:oldbr bash "$JANITOR" "$G/repo" >"$SB/gh-stacked.log" 2>&1
check "dry-run skips a branch that an open PR in origin (asked by -R) uses as its base" \
  matching '- SKIP \(このブランチを base にする open PR あり\): origin/oldbr' "$SB/gh-stacked.log"

# origin that is not a GitHub URL: gh cannot tell which repository's PRs it sees, so remote branches stay.
P="$SB/plainorigin"
git init -q --bare "$P/origin.git"
git clone -q "$P/origin.git" "$P/repo" 2>/dev/null
at 30 -C "$P/repo" commit -q --allow-empty -m init
git -C "$P/repo" checkout -q -b pb
at 13 -C "$P/repo" commit -q --allow-empty -m pb
git -C "$P/repo" checkout -q develop
at 11 -C "$P/repo" merge -q --no-ff -m "merge pb" pb
git -C "$P/repo" push -q origin develop pb
bash "$JANITOR" "$P/repo" --apply --remote >"$SB/plainorigin.log" 2>&1
check "--apply --remote keeps remote branches when origin is not a GitHub URL" has "$P/origin.git" pb
check "--apply --remote says it cannot check PRs for a non-GitHub origin" \
  matching '- SKIP \(open PR の有無を確かめられない\): origin/pb' "$SB/plainorigin.log"

# A local branch named origin/develop must not stand in for the base branch: git resolves the short
# name to refs/heads/origin/develop first.
A="$SB/ambiguous"
git init -q --bare "$A/origin.git"
git clone -q "$A/origin.git" "$A/repo" 2>/dev/null
git -C "$A/repo" config url."$A/origin.git".insteadOf https://github.com/acme/ambiguous.git
git -C "$A/repo" remote set-url origin https://github.com/acme/ambiguous.git
at 30 -C "$A/repo" commit -q --allow-empty -m init
git -C "$A/repo" push -q origin develop
git -C "$A/repo" checkout -q -b sneaky
at 13 -C "$A/repo" commit -q --allow-empty -m sneaky
git -C "$A/repo" push -q origin sneaky
git -C "$A/repo" checkout -q -b origin/develop develop
at 11 -C "$A/repo" merge -q --no-ff -m "merge sneaky" sneaky
git -C "$A/repo" checkout -q develop
bash "$JANITOR" "$A/repo" --apply --remote >"$SB/ambiguous.log" 2>&1
check "--apply --remote keeps a remote branch that only a local branch named origin/develop contains" \
  has "$A/origin.git" sneaky

# Changes git status hides: untracked files under status.showUntrackedFiles=no, and edits to
# skip-worktree / assume-unchanged files. git worktree remove misses them too, so the janitor must not
# get that far. The control worktree is clean and must go, so the scenario is not vacuous.
# A lossy clean filter (the nbstripout pattern) hides working-tree content from git status once it is
# added: *.ipynb drops OUTPUT lines. *.bin is under a stand-in for Git LFS, whose working tree always
# differs from the index; it must not keep the control worktree.
H="$SB/hidden"
git init -q --bare "$H/origin.git"
git clone -q "$H/origin.git" "$H/repo" 2>/dev/null
git -C "$H/repo" config status.showUntrackedFiles no
git -C "$H/repo" config filter.strip.clean "sed '/^OUTPUT/d'"
git -C "$H/repo" config filter.lfs.clean "sed 's/^REAL/POINTER/'"
git -C "$H/repo" config filter.lfs.smudge "sed 's/^POINTER/REAL/'"
printf '*.ipynb filter=strip\n*.bin filter=lfs\n' >"$H/repo/.gitattributes"
printf 'base\n' >"$H/repo/conf.txt"
printf 'cell 1\n' >"$H/repo/nb.ipynb"
printf 'REAL data\n' >"$H/repo/data.bin"
git -C "$H/repo" add .gitattributes conf.txt nb.ipynb data.bin
at 30 -C "$H/repo" commit -q -m init
for b in hu-br sw-br au-br ctl-br fl-br; do
  git -C "$H/repo" checkout -q -b "$b" develop
  at 13 -C "$H/repo" commit -q --allow-empty -m "$b"
  git -C "$H/repo" checkout -q develop
  at 11 -C "$H/repo" merge -q --no-ff -m "merge $b" "$b"
done
git -C "$H/repo" push -q origin develop
at 11 -C "$H/repo" worktree add -q "$H/wt/untracked" hu-br
printf 'draft\n' >"$H/wt/untracked/draft.md"
at 11 -C "$H/repo" worktree add -q "$H/wt/skipped" sw-br
git -C "$H/wt/skipped" update-index --skip-worktree conf.txt
printf 'local edit\n' >"$H/wt/skipped/conf.txt"
at 11 -C "$H/repo" worktree add -q "$H/wt/assumed" au-br
git -C "$H/wt/assumed" update-index --assume-unchanged conf.txt
printf 'local edit\n' >"$H/wt/assumed/conf.txt"
at 11 -C "$H/repo" worktree add -q "$H/wt/control" ctl-br
at 11 -C "$H/repo" worktree add -q "$H/wt/filtered" fl-br
printf 'OUTPUT 42\n' >>"$H/wt/filtered/nb.ipynb"
git -C "$H/wt/filtered" add nb.ipynb
bash "$JANITOR" "$H/repo" --apply >"$SB/hidden.log" 2>&1
check "--apply keeps a worktree whose untracked file status.showUntrackedFiles=no hides" \
  [ -f "$H/wt/untracked/draft.md" ]
check "--apply keeps a worktree with a skip-worktree file it edited" grep -qx 'local edit' "$H/wt/skipped/conf.txt"
check "--apply keeps a worktree with an assume-unchanged file it edited" grep -qx 'local edit' "$H/wt/assumed/conf.txt"
check "--apply still removes a clean worktree in the same repository" [ ! -e "$H/wt/control" ]
check "--apply says why it kept the worktree with a hidden edit" \
  matching '- SKIP \(変更が git status に出ないファイルがある: .*\): .*/skipped \[sw-br\]$' "$SB/hidden.log"
check "--apply keeps a worktree whose lossy clean filter hides working-tree content" \
  grep -qx 'OUTPUT 42' "$H/wt/filtered/nb.ipynb"
check "--apply says which file the clean filter hides" \
  matching '- SKIP \(clean filter で git status に出ない中身がある: nb\.ipynb.*\): .*/filtered \[fl-br\]$' "$SB/hidden.log"

# A submodule edit that submodule.<name>.ignore=all hides from the default git status. (git worktree
# remove refuses a worktree with a populated submodule anyway, so the plan is what shows the check.)
SM="$SB/submod"
git init -q --bare "$SM/origin.git"
git clone -q "$SM/origin.git" "$SM/repo" 2>/dev/null
git init -q "$SM/libsrc"
printf 'v1\n' >"$SM/libsrc/lib.txt"
git -C "$SM/libsrc" add lib.txt
at 30 -C "$SM/libsrc" commit -q -m lib
at 30 -C "$SM/repo" commit -q --allow-empty -m init
git -C "$SM/repo" -c protocol.file.allow=always submodule add -q "$SM/libsrc" lib >/dev/null 2>&1
git -C "$SM/repo" config -f .gitmodules submodule.lib.ignore all
git -C "$SM/repo" add .gitmodules
at 30 -C "$SM/repo" commit -q -m "add lib"
git -C "$SM/repo" checkout -q -b sm-br
at 13 -C "$SM/repo" commit -q --allow-empty -m sm-br
git -C "$SM/repo" checkout -q develop
at 11 -C "$SM/repo" merge -q --no-ff -m "merge sm-br" sm-br
git -C "$SM/repo" push -q origin develop
at 11 -C "$SM/repo" worktree add -q "$SM/wt/subwt" sm-br
git -C "$SM/wt/subwt" -c protocol.file.allow=always submodule update -q --init >/dev/null 2>&1
printf 'edited\n' >>"$SM/wt/subwt/lib/lib.txt"
bash "$JANITOR" "$SM/repo" >"$SB/submod.log" 2>&1
check "dry-run skips a worktree whose submodule edit submodule.<name>.ignore=all hides" \
  matching '- SKIP \(dirty [0-9]+files\): .*/subwt \[sm-br\]$' "$SB/submod.log"

# Tags with the same name as a merged remote branch. The delete must name refs/heads/: a short name
# is refused when both exist, and deletes the tag when the branch is already gone. Fetch from a mirror
# taken before `gone` lost its branch; push to the real origin.
TQ="$SB/tagclash"
git init -q --bare "$TQ/origin.git"
git clone -q "$TQ/origin.git" "$TQ/repo" 2>/dev/null
at 30 -C "$TQ/repo" commit -q --allow-empty -m init
for b in both gone; do
  git -C "$TQ/repo" checkout -q -b "$b"
  at 13 -C "$TQ/repo" commit -q --allow-empty -m "$b"
  git -C "$TQ/repo" checkout -q develop
  at 11 -C "$TQ/repo" merge -q --no-ff -m "merge $b" "$b"
done
git -C "$TQ/repo" push -q origin develop both gone
git -C "$TQ/repo" tag tag-both both
git -C "$TQ/repo" tag tag-gone gone
git -C "$TQ/repo" push -q origin refs/tags/tag-both:refs/tags/both refs/tags/tag-gone:refs/tags/gone
git clone -q --bare "$TQ/origin.git" "$TQ/mirror.git"
git -C "$TQ/origin.git" update-ref -d refs/heads/gone
git -C "$TQ/repo" config url."$TQ/mirror.git".insteadOf https://github.com/acme/tagclash.git
git -C "$TQ/repo" config url."$TQ/origin.git".pushInsteadOf https://github.com/acme/tagclash.git
git -C "$TQ/repo" remote set-url origin https://github.com/acme/tagclash.git
bash "$JANITOR" "$TQ/repo" --apply --remote >"$SB/tagclash.log" 2>&1
check "--apply --remote deletes a remote branch that shares its name with a tag" lacks "$TQ/origin.git" both
check "--apply --remote keeps the tag with the same name as the branch it deletes" \
  git -C "$TQ/origin.git" show-ref --verify --quiet refs/tags/both
check "--apply --remote never deletes a tag when the branch of that name is already gone" \
  git -C "$TQ/origin.git" show-ref --verify --quiet refs/tags/gone

# A path that cannot be entered must stop the janitor, not clean the current directory's repo.
out=$(cd "$R" && bash "$JANITOR" "$SB/no-such-dir" 2>&1)
rc=$?
check "a path it cannot enter stops the janitor" [ "$rc" -ne 0 ]
check "a path it cannot enter prints no plan" not_matching '^## Worktrees' "$out"

# Mutants: each removes one behavior; the check that pins it must fail.
# The old/new texts below are literal script source, so they must not expand.
# shellcheck disable=SC2016
if [ -z "${JANITOR_UNDER_TEST:-}" ]; then
  # Each mutant run builds its own sandbox, so up to MUTANT_JOBS of them run at once; the verdicts are
  # checked after all of them finish. bash 4.3+ waits for any one job (`wait -n`, whose status is that
  # job's: a caught mutant exits 1, so it must not fall through to waiting for all); bash 3.2 has no
  # `wait -n` and waits for the whole batch.
  MUTANT_JOBS=${MUTANT_JOBS:-4}
  WAIT_ANY=false
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
    WAIT_ANY=true
  fi
  M_NAMES=()
  M_EXPECT=()
  # caught_by <name> <expected FAIL line> <old text> <new text>
  caught_by() {
    local m="$SB/mutant-$1.sh"
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
    M_NAMES+=("$1")
    M_EXPECT+=("$2")
    JANITOR_UNDER_TEST="$m" bash "$SELF" >"$SB/mutant-$1.out" 2>&1 &
    if [ "$(jobs -rp | wc -l)" -ge "$MUTANT_JOBS" ]; then
      if $WAIT_ANY; then wait -n || :; else wait; fi
    fi
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
  caught_by no-worktree-creation-check "--apply keeps a worktree created today on an old merged branch" \
    '    if created_recently "$wt" HEAD; then' '    if false; then'
  caught_by no-branch-creation-check "--apply keeps a branch created today with no commits of its own" \
    $'  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/heads/$br"; then\n    echo "- KEEP (no own commits, created' \
    $'  if false; then\n    echo "- KEEP (no own commits, created'
  caught_by no-fast-forward-check "dry-run keeps a branch fast-forwarded into develop today" \
    $'  if $ON_CHAIN && observed_young "refs/heads/$br"; then\n    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $br"' \
    $'  if false; then\n    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $br"'
  # The plan-time checks below are also re-run right before removal (--apply), which keeps the worktree
  # anyway, so their mutants show in the plan the user approves: the dry-run.
  caught_by ignored-files-removed "dry-run skips a worktree with an ignored file that is not regenerable" \
    '    if [ -n "$ignored" ]; then' '    if false; then'
  caught_by removes-its-own-worktree "--apply keeps the worktree it runs from" \
    '  if [ -n "$real" ]; then' '  if false; then'
  caught_by protected-remote-deleted "--apply keeps origin/main" \
    '  echo "$br" | grep -Eq "$PROTECTED" && continue # リモートの保護ブランチ' ''
  caught_by kept-worktree-branch-listed "dry-run does not list a branch checked out in a kept worktree" \
    $'  if kept_checkout "$br"; then\n    echo "- SKIP (checked out in worktree): $br"' \
    $'  if false; then\n    echo "- SKIP (checked out in worktree): $br"'
  caught_by no-gh-repo "gh gets -R owner/repo for an https origin" \
    '[ -n "$origin_slug" ] && GH_REPO_ARGS=(-R "$origin_slug")' ':'
  caught_by gh-failure-deletes "--apply keeps a remote branch whose PRs cannot be checked" \
    $'\n    --json number -q length 2>/dev/null) || open=""' $'\n    --json number -q length 2>/dev/null) || open=0'
  caught_by no-parent-check "dry-run skips a branch with an open PR in the fork's parent" \
    '  if [ "$open" = 0 ]; then' '  if false; then'
  caught_by fetch-failure-ignored "--apply --remote keeps remote branches when fetch fails" \
    $'  FETCH_OK=false\n' $'  FETCH_OK=true\n'
  fetch_block=$'FETCH_OK=true\ngit fetch --prune origin >/dev/null 2>&1 || {\n  FETCH_OK=false\n  echo "WARN: fetch失敗（オフライン?）。ローカル情報のみで判定し、リモートは消さない。"\n}\n'
  base_block=$'\n# 統合ブランチの決定 (develop 優先)。fetch の後で選ぶ（前回の fetch 以降に作られた develop を見落とさない）\nif git show-ref --verify --quiet refs/remotes/origin/develop; then BASE=origin/develop\nelif git show-ref --verify --quiet refs/remotes/origin/main; then BASE=origin/main\nelse BASE=origin/master; fi\nBASE_NAME=${BASE#origin/}\n'
  caught_by base-before-fetch "dry-run picks the base branch after fetching" \
    "$fetch_block$base_block" "$base_block$fetch_block"
  caught_by no-lease "--apply --remote keeps a remote branch that moved after the fetch" \
    'git push --force-with-lease="refs/heads/$br:${REMOTE_SHA[$i]}" origin ":refs/heads/$br"' \
    'git push origin ":refs/heads/$br"'
  caught_by git-env-inherited "the janitor ignores GIT_DIR inherited from the caller" \
    $'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \\\n  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE\n' \
    $':\n'
  caught_by untracked-hidden "--apply keeps a worktree whose untracked file status.showUntrackedFiles=no hides" \
    'status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null); then' \
    'status --porcelain 2>/dev/null); then'
  caught_by hidden-flags-ignored "--apply keeps a worktree with a skip-worktree file it edited" \
    "  if printf '%s\\n' \"\$flags\" | grep -q '^[a-zS] '; then" '  if false; then'
  caught_by short-base-ref "--apply --remote keeps a remote branch that only a local branch named origin/develop contains" \
    'BASE_REF="refs/remotes/$BASE"' 'BASE_REF="$BASE"'
  caught_by prune-no-expire "--apply keeps the admin data of a worktree whose directory vanished today" \
    'PRUNE_EXPIRE="${MIN_AGE_DAYS}.days.ago"' 'PRUNE_EXPIRE=now'
  caught_by non-github-deletes "--apply --remote keeps remote branches when origin is not a GitHub URL" \
    $'GH_PARENTS_OK=false\nif [ -n "$origin_slug" ]; then' $'GH_PARENTS_OK=true\nif [ -n "$origin_slug" ]; then'
  caught_by no-stacked-check "--apply keeps a remote branch that an open PR uses as its base" \
    '  stacked=$(gh pr list' '  stacked=0; : $(gh pr list'
  caught_by stacked-failure-deletes "--apply keeps a remote branch whose stacked PRs cannot be checked" \
    '2>/dev/null) || stacked=""' '2>/dev/null) || stacked=0'
  caught_by kept-worktree-remote-deleted \
    "dry-run skips the remote branch of a branch checked out in a kept worktree" \
    $'  if kept_checkout "$br"; then\n    echo "- SKIP (残す worktree で checkout 中): origin/$br"' \
    $'  if false; then\n    echo "- SKIP (残す worktree で checkout 中): origin/$br"'
  caught_by local-protected-deleted "--apply keeps a local protected branch (master)" \
    $'  echo "$br" | grep -Eq "$PROTECTED" && continue\n  [ "$br" = "$CURRENT" ]' $'  [ "$br" = "$CURRENT" ]'
  caught_by worktree-protected-removed "--apply keeps a worktree on a protected branch (stg)" \
    '  if echo "$br" | grep -Eq "$PROTECTED"; then' '  if false; then'
  caught_by no-remote-fast-forward-check "--apply --remote keeps a remote branch fast-forwarded into develop today" \
    '  if $ON_CHAIN && observed_young "refs/remotes/$ref"; then' '  if false; then'
  caught_by no-remote-creation-check "--apply --remote keeps a remote branch pushed today at an old develop commit" \
    '  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/remotes/$ref"; then' '  if false; then'
  caught_by no-worktree-branch-creation-check \
    "--apply keeps a worktree switched today to a new branch with no commits of its own" \
    '    if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/heads/$br"; then' '    if false; then'
  caught_by no-worktree-fast-forward-check "--apply keeps a worktree whose branch was fast-forwarded into develop today" \
    '    if $ON_CHAIN && observed_young "refs/heads/$br"; then' '    if false; then'
  caught_by tag-shadows-branch "dry-run keeps the branch that entered develop 1 day ago" \
    $'  if too_young "refs/heads/$br"; then\n    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"' \
    $'  if too_young "$br"; then\n    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"'
  caught_by plan-after-prune "--apply keeps the branch of a worktree it pruned in this run (the approved dry-run kept it)" \
    'WT_SNAPSHOT=$(git worktree list --porcelain)' \
    'WT_SNAPSHOT=$($APPLY && git worktree prune --expire "${MIN_AGE_DAYS}.days.ago"; git worktree list --porcelain)'
  caught_by locked-planned "dry-run skips a locked worktree" \
    '"$WT_LOCKED" | grep -qxF -- "$wt"; then' '"$WT_LOCKED" | grep -qxF -- "$wt" && false; then'
  caught_by kept-from-whole-list "--apply --remote deletes the remote branch of a worktree it removes" \
    '  in_list "$p" ${WT_REMOVE[@]+"${WT_REMOVE[@]}"} && continue' '  :'
  caught_by no-live-remote-recheck "--apply --remote keeps the remote branch of a worktree it did not remove after all" \
    $'    if still_checked_out "$br"; then\n      echo "- SKIP (worktree でまだ checkout 中): origin/$br"' \
    $'    if false; then\n      echo "- SKIP (worktree でまだ checkout 中): origin/$br"'
  caught_by no-recheck-before-remove "--apply keeps a worktree that gained an ignored file after the plan" \
    '    if ! ignored=$(unregenerable_ignored "$wt") || [ -n "$ignored" ]; then' '    if false; then'
  caught_by lossy-filter-ignored "--apply keeps a worktree whose lossy clean filter hides working-tree content" \
    '  if [ -n "$lossy" ]; then' '  if false; then'
  caught_by lfs-counted-as-lossy "--apply still removes a clean worktree in the same repository" \
    "':(exclude,attr:filter=lfs)'" "':(exclude,attr:filter=none)'"
  caught_by delete-by-short-name "--apply --remote never deletes a tag when the branch of that name is already gone" \
    'origin ":refs/heads/$br"' 'origin --delete "$br"'
  caught_by stacked-without-repo "dry-run skips a branch that an open PR in origin (asked by -R) uses as its base" \
    '  stacked=$(gh pr list ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --base' '  stacked=$(gh pr list --base'
  caught_by submodule-edits-hidden "dry-run skips a worktree whose submodule edit submodule.<name>.ignore=all hides" \
    ' --ignore-submodules=none 2>/dev/null); then' ' 2>/dev/null); then'
  caught_by parent-only "dry-run skips a branch with an open PR in the fork's grandparent" \
    'for _ in $(seq "$GH_PARENT_DEPTH"); do' 'for _ in 1; do'
  wait
  for i in ${M_NAMES[@]+"${!M_NAMES[@]}"}; do
    check "mutant ${M_NAMES[$i]} is caught by: ${M_EXPECT[$i]}" \
      grep -qF "FAIL: ${M_EXPECT[$i]}" "$SB/mutant-${M_NAMES[$i]}.out"
  done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
