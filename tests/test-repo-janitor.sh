#!/usr/bin/env bash
# scripts/repo-janitor.sh deletes only what entered the base branch 7 or more days ago
# (rules/git-workflow.md「機械掃除は マージ済み + 7 日 限定」) and, for worktrees and branches with no
# commits of their own, only what was created and first seen in the base 7 or more days ago. It never
# lists origin/HEAD, never touches protected branches, the worktree it runs from or was given, a
# branch checked out in a kept worktree, a worktree holding ignored files that the handover criteria
# do not list as regenerable, or a remote branch whose open PRs (in origin or its fork parent) gh
# cannot rule out; it picks the base after fetching, keeps remote branches when fetch fails, passes
# -R owner/repo to gh, deletes remote branches before local ones (so git branch -d is not refused by
# an upstream it is ahead of), guards each remote delete with --force-with-lease, reports refusals
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

# gh stub. `gh repo view ...` prints FAKE_GH_PARENT (fails when FAKE_GH_PARENT_FAIL is set).
# `gh pr list [-R <repo>] --head <branch> --state open --json number -q length` prints 1 for branches
# in FAKE_GH_OPEN or <repo>:<branch> pairs in FAKE_GH_OPEN_AT, else 0, and fails for branches in
# FAKE_GH_FAIL. Every call appends its arguments to GH_LOG when that is set.
mkdir -p "$SB/bin"
cat >"$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = repo ] && [ "${2:-}" = view ]; then
  [ -n "${FAKE_GH_PARENT_FAIL:-}" ] && exit 1
  printf '%s\n' "${FAKE_GH_PARENT:-}"
  exit 0
fi
head=""
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="${2:-}" ;;
    -R) repo="${2:-}" ;;
  esac
  shift
done
for b in ${FAKE_GH_FAIL:-}; do [ "$b" = "$head" ] && exit 1; done
for b in ${FAKE_GH_OPEN:-}; do [ "$b" = "$head" ] && { echo 1; exit 0; }; done
for b in ${FAKE_GH_OPEN_AT:-}; do [ "$b" = "$repo:$head" ] && { echo 1; exit 0; }; done
echo 0
EOF
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" FAKE_GH_OPEN=open-pr FAKE_GH_FAIL=gh-down

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
for b in wt-old-br dirty-br self-br resume-br log-br gh-down; do
  feature "$b" 13
  merge "$b" 11
done
feature mainlike 14
merge mainlike 13
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
git -C "$R" push -q origin develop old-merged open-pr new-merged gh-down
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

out=$(bash "$JANITOR" "$W/self" 2>&1)
check "dry-run skips the worktree it was given" \
  grep -qE -- '- SKIP \(この実行が使っている worktree\): .*/self \[self-br\]$' <<<"$out"

# The caller's git environment must not redirect the janitor to another repository.
git init -q "$SB/elsewhere"
at 30 -C "$SB/elsewhere" commit -q --allow-empty -m elsewhere
out=$(GIT_DIR="$SB/elsewhere/.git" GIT_WORK_TREE="$SB/elsewhere" bash "$JANITOR" "$R" 2>&1)
check "the janitor ignores GIT_DIR inherited from the caller" grep -qF -- '- 削除候補: old-merged（' <<<"$out"

# The real run starts inside the self worktree, which must survive it.
(cd "$W/self" && bash "$JANITOR" "$R" --apply --remote) >"$SB/apply.log" 2>&1
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
check "--apply reports why git refused to delete a branch" \
  matching "- FAILED \(-d拒否\): lagging — .*not fully merged" "$SB/apply.log"

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
git -C "$L/repo" remote set-url origin "$L/mirror.git"
git -C "$L/repo" remote set-url --push origin "$L/origin.git"
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
git -C "$F/repo" remote set-url origin "$F/missing.git"
git -C "$F/repo" remote set-url --push origin "$F/origin.git"
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
FAKE_GH_PARENT=acme/upstream FAKE_GH_OPEN_AT=acme/upstream:oldbr bash "$JANITOR" "$G/repo" >"$SB/gh-fork.log" 2>&1
check "dry-run skips a branch with an open PR in the fork's parent" \
  matching '- SKIP \(open PRあり\): origin/oldbr' "$SB/gh-fork.log"
FAKE_GH_PARENT_FAIL=1 bash "$JANITOR" "$G/repo" >"$SB/gh-noparent.log" 2>&1
check "dry-run skips remote branches when the fork parent cannot be checked" \
  matching '- SKIP \(open PR の有無を確かめられない\): origin/oldbr' "$SB/gh-noparent.log"

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
  caught_by no-worktree-creation-check "--apply keeps a worktree created today on an old merged branch" \
    '    if created_recently "$wt" HEAD; then' '    if false; then'
  caught_by no-branch-creation-check "--apply keeps a branch created today with no commits of its own" \
    $'  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/heads/$br"; then\n    echo "- KEEP (no own commits, created' \
    $'  if false; then\n    echo "- KEEP (no own commits, created'
  caught_by no-fast-forward-check "dry-run keeps a branch fast-forwarded into develop today" \
    $'  if $ON_CHAIN && observed_young "refs/heads/$br"; then\n    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $br"' \
    $'  if false; then\n    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $br"'
  caught_by ignored-files-removed "--apply keeps a worktree with an ignored file that is not regenerable" \
    '    if [ -n "$ignored" ]; then' '    if false; then'
  caught_by removes-its-own-worktree "--apply keeps the worktree it runs from" \
    '  if [ -n "$real" ]; then' '  if false; then'
  caught_by protected-remote-deleted "--apply keeps origin/main" \
    '  echo "$br" | grep -Eq "$PROTECTED" && continue # リモートの保護ブランチ' ''
  caught_by kept-worktree-branch-listed "dry-run does not list a branch checked out in a kept worktree" \
    '    if ! in_list "$br" ${WT_FREED[@]+"${WT_FREED[@]}"}; then' '    if false; then'
  caught_by no-gh-repo "gh gets -R owner/repo for an https origin" \
    '[ -n "$origin_slug" ] && GH_REPO_ARGS=(-R "$origin_slug")' ':'
  caught_by gh-failure-deletes "--apply keeps a remote branch whose PRs cannot be checked" \
    $'\n    --json number -q length 2>/dev/null) || open=""' $'\n    --json number -q length 2>/dev/null) || open=0'
  caught_by no-parent-check "dry-run skips a branch with an open PR in the fork's parent" \
    '  if [ "$open" = 0 ] && [ -n "$GH_PARENT" ]; then' '  if false; then'
  caught_by fetch-failure-ignored "--apply --remote keeps remote branches when fetch fails" \
    $'  FETCH_OK=false\n' $'  FETCH_OK=true\n'
  fetch_block=$'FETCH_OK=true\ngit fetch --prune origin >/dev/null 2>&1 || {\n  FETCH_OK=false\n  echo "WARN: fetch失敗（オフライン?）。ローカル情報のみで判定し、リモートは消さない。"\n}\n'
  base_block=$'\n# 統合ブランチの決定 (develop 優先)。fetch の後で選ぶ（前回の fetch 以降に作られた develop を見落とさない）\nif git show-ref --verify --quiet refs/remotes/origin/develop; then BASE=origin/develop\nelif git show-ref --verify --quiet refs/remotes/origin/main; then BASE=origin/main\nelse BASE=origin/master; fi\nBASE_NAME=${BASE#origin/}\n'
  caught_by base-before-fetch "dry-run picks the base branch after fetching" \
    "$fetch_block$base_block" "$base_block$fetch_block"
  caught_by no-lease "--apply --remote keeps a remote branch that moved after the fetch" \
    'git push --force-with-lease="refs/heads/$br:${REMOTE_SHA[$i]}" origin --delete "$br"' \
    'git push origin --delete "$br"'
  caught_by git-env-inherited "the janitor ignores GIT_DIR inherited from the caller" \
    $'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \\\n  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE\n' \
    $':\n'
  caught_by tag-shadows-branch "dry-run keeps the branch that entered develop 1 day ago" \
    $'  if too_young "refs/heads/$br"; then\n    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"' \
    $'  if too_young "$br"; then\n    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"'
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
