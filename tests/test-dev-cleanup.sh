#!/usr/bin/env bash
# scripts/dev-cleanup.sh deletes build caches only with --apply, and only where the git repository
# that owns the cache (a main checkout with its linked worktrees) has had no commit for 90+ days
# and has no uncommitted work. Directories outside git count as stale by design. The accident this
# pins: deleting caches of work still in use — an active project, an active or dirty worktree inside
# an old repository (the <repo>/.worktrees/<agent>/<slug> layout of AGENTS.md), a linked worktree,
# an active repository inside a folder that is not a repository, or a repository with no commits
# yet — and a failure that stops the sweep or is reported as freed. It also pins caches that must
# be found: deep inside a worktree, inside a stale repository nested in an active one, and under a
# target/ that is not a build directory.
# The test writes mutants of the script and runs itself against each one (DEV_SCRIPT) to show that
# the check pinning each behavior fails without it.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/tests/$(basename "$0")"
SRC="$ROOT/scripts/dev-cleanup.sh"
SCRIPT="${DEV_SCRIPT:-$SRC}"
SB=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$SB" 2>/dev/null; rm -rf "$SB"' EXIT
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

not_listed() {
  ! grep -q "$1" "$2"
}

# deleted_total <log>: the sum of the sizes on the DELETED lines
deleted_total() {
  sed -n 's/^DELETED \([0-9]*\)MB: .*/\1/p' "$1" | awk '{s += $1} END {print s + 0}'
}

g() {
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c user.name=test -c user.email=test@example.com "$@"
}

# cache <dir> [name]: an 11 MB cache directory (the script ignores caches under 10 MB)
cache() {
  mkdir -p "$1/${2:-node_modules}"
  dd if=/dev/zero of="$1/${2:-node_modules}/blob" bs=1048576 count=11 2>/dev/null
}

# commit_at <repo or worktree> <days ago> [file...]: commit the named files (created if missing)
commit_at() {
  local dir="$1" when f
  when=$(($(date +%s) - $2 * 86400))
  shift 2
  for f in "$@"; do
    [ -e "$dir/$f" ] || printf '%s\n' "$f" >"$dir/$f"
    g -C "$dir" add -- "$f"
  done
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" g -C "$dir" commit -q --allow-empty -m "c$when"
}

# repo <dir> <days since the last commit> [file...]: a git repository with a cache
repo() {
  local dir="$1" days="$2"
  shift 2
  cache "$dir"
  git init -q "$dir"
  commit_at "$dir" "$days" "$@"
}

# ignore_worktrees <repo>: the AGENTS.md layout keeps .worktrees/ out of git
ignore_worktrees() {
  printf '.worktrees/\n' >"$1/.gitignore"
}

D="$SB/dev"
repo "$D/active" 1
repo "$D/stale" 100
cache "$D/stale/packages/app"
repo "$D/edge89" 89
repo "$D/edge91" 91
for skip in _archive _repo-backups _sandbox; do cache "$D/$skip/old"; done
cache "$D/plain"
repo "$D/group/app" 1
repo "$D/group/oldapp" 100
cache "$D/unborn"
git init -q "$D/unborn"
# an old repository with a recently committed worktree
mkdir -p "$D/oldrepo"
ignore_worktrees "$D/oldrepo"
repo "$D/oldrepo" 200 .gitignore
g -C "$D/oldrepo" worktree add -q "$D/oldrepo/.worktrees/claude/feat" -b feat
commit_at "$D/oldrepo/.worktrees/claude/feat" 1
cache "$D/oldrepo/.worktrees/claude/feat"
# an old checkout whose only recent commit is on a branch that is not checked out anywhere
# (no worktree, so the result cannot depend on which path is judged first)
repo "$D/branchonly" 200
g -C "$D/branchonly" checkout -q -b recent
commit_at "$D/branchonly" 1
g -C "$D/branchonly" checkout -q -
# an old repository whose worktree has an uncommitted edit
mkdir -p "$D/wiprepo"
ignore_worktrees "$D/wiprepo"
repo "$D/wiprepo" 100 .gitignore src.txt
g -C "$D/wiprepo" worktree add -q "$D/wiprepo/.worktrees/claude/wip" -b wip
printf 'edited\n' >>"$D/wiprepo/.worktrees/claude/wip/src.txt"
cache "$D/wiprepo/.worktrees/claude/wip"
# an old repository with a new file that is not committed yet
repo "$D/newfile" 100
printf 'draft\n' >"$D/newfile/feature.ts"
# an old repository whose clean worktree has a cache six levels down
mkdir -p "$D/deeprepo"
ignore_worktrees "$D/deeprepo"
repo "$D/deeprepo" 100 .gitignore
g -C "$D/deeprepo" worktree add -q "$D/deeprepo/.worktrees/claude/stalewt" -b stalewt
cache "$D/deeprepo/.worktrees/claude/stalewt/packages/web"
# a stale repository cloned inside an active one
repo "$D/activeparent" 1
repo "$D/activeparent/vendor/oldlib" 100
g -C "$D/active" worktree add -q "$D/linked" -b linked
commit_at "$D/linked" 1
cache "$D/linked"
mkdir -p "$D/rust"
repo "$D/rust" 100 Cargo.toml
cache "$D/rust" target
repo "$D/py" 100
cache "$D/py" .venv
touch "$D/py/.venv/pyvenv.cfg"
repo "$D/data" 100
cache "$D/data" target
cache "$D/data" venv
cache "$D/data/target/web"
# an old repository that commits a file under node_modules/ and has an uncommitted edit to it
repo "$D/trackedcache" 100 node_modules/patch.js
printf 'edited\n' >>"$D/trackedcache/node_modules/patch.js"
# an old repository where git status fails (git log still works)
repo "$D/brokenstatus" 100
git -C "$D/brokenstatus" config status.showUntrackedFiles bogus

DEV_DIR="$D" bash "$SCRIPT" >"$SB/dry.log" 2>&1
rc=$?
check "dry-run exits 0" [ "$rc" -eq 0 ]
check "dry-run keeps the stale project's cache" [ -d "$D/stale/node_modules" ]
check "dry-run lists the stale cache" grep -q "candidate .*/stale/node_modules" "$SB/dry.log"
check "dry-run does not list the active cache" not_listed "/active/node_modules" "$SB/dry.log"

DEV_DIR="$D" bash "$SCRIPT" --apply >"$SB/apply.log" 2>&1
rc=$?
check "--apply exits 0" [ "$rc" -eq 0 ]
check "--apply deletes the stale project's cache" [ ! -e "$D/stale/node_modules" ]
check "--apply deletes a stale cache three levels down" [ ! -e "$D/stale/packages/app/node_modules" ]
check "--apply deletes the cache of a project idle for 91 days" [ ! -e "$D/edge91/node_modules" ]
check "--apply deletes the cache of a folder outside git" [ ! -e "$D/plain/node_modules" ]
check "--apply deletes a stale repository's cache inside a plain folder" [ ! -e "$D/group/oldapp/node_modules" ]
check "--apply deletes target/ next to Cargo.toml" [ ! -e "$D/rust/target" ]
check "--apply deletes .venv/ with pyvenv.cfg" [ ! -e "$D/py/.venv" ]
check "--apply deletes a stale worktree's cache six levels down" \
  [ ! -e "$D/deeprepo/.worktrees/claude/stalewt/packages/web/node_modules" ]
check "--apply deletes a stale repository's cache inside an active one" \
  [ ! -e "$D/activeparent/vendor/oldlib/node_modules" ]
check "--apply deletes a cache under a target/ that is not a build directory" \
  [ ! -e "$D/data/target/web/node_modules" ]
check "--apply keeps the active project's cache" [ -d "$D/active/node_modules" ]
check "--apply keeps the cache of a project idle for 89 days" [ -d "$D/edge89/node_modules" ]
for skip in _archive _repo-backups _sandbox; do
  check "--apply skips $skip" [ -d "$D/$skip/old/node_modules" ]
done
check "--apply keeps an active repository's cache inside a plain folder" [ -d "$D/group/app/node_modules" ]
check "--apply keeps the cache of a repository with no commits" [ -d "$D/unborn/node_modules" ]
check "--apply keeps an active worktree's cache inside an old repository" \
  [ -d "$D/oldrepo/.worktrees/claude/feat/node_modules" ]
check "--apply keeps the old repository's own cache while its worktree is active" \
  [ -d "$D/oldrepo/node_modules" ]
check "--apply keeps the cache of an old checkout whose other branch has a recent commit" \
  [ -d "$D/branchonly/node_modules" ]
check "--apply keeps the cache of a worktree with an uncommitted edit" \
  [ -d "$D/wiprepo/.worktrees/claude/wip/node_modules" ]
check "--apply keeps the repository's own cache while its worktree has an uncommitted edit" \
  [ -d "$D/wiprepo/node_modules" ]
check "--apply keeps the cache of a repository with an uncommitted new file" [ -d "$D/newfile/node_modules" ]
check "--apply keeps the active parent's own cache" [ -d "$D/activeparent/node_modules" ]
check "--apply keeps a linked worktree's cache" [ -d "$D/linked/node_modules" ]
check "--apply keeps target/ without Cargo.toml or pom.xml" [ -d "$D/data/target" ]
check "--apply keeps venv/ without pyvenv.cfg" [ -d "$D/data/venv" ]
check "--apply keeps a cache holding a tracked file with an uncommitted edit" \
  [ -f "$D/trackedcache/node_modules/patch.js" ]
check "--apply keeps the cache of a repository whose status cannot be read" [ -d "$D/brokenstatus/node_modules" ]
check "--apply does not suggest archiving the repository with no commits" \
  not_listed "ARCHIVE.*: unborn " "$SB/apply.log"
check "dry-run suggests archiving a folder outside git with no repository inside" \
  grep -q "ARCHIVE.*: plain " "$SB/dry.log"
check "dry-run does not suggest archiving a folder with an active repository inside" \
  not_listed "ARCHIVE.*: group " "$SB/dry.log"

# An unreadable or undeletable cache must neither stop the sweep nor count as freed.
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: permission checks (running as root)\n'
else
  E="$SB/perm"
  repo "$E/alpha" 100
  mkdir -p "$E/alpha/node_modules/locked"
  touch "$E/alpha/node_modules/locked/file"
  chmod 000 "$E/alpha/node_modules/locked"
  repo "$E/beta" 100

  DEV_DIR="$E" bash "$SCRIPT" >"$SB/perm-dry.log" 2>&1
  check "dry-run continues past an unreadable cache" grep -q "candidate .*/beta/node_modules" "$SB/perm-dry.log"

  DEV_DIR="$E" bash "$SCRIPT" --apply >"$SB/perm-apply.log" 2>&1
  rc=$?
  check "--apply deletes the next project's cache" [ ! -e "$E/beta/node_modules" ]
  check "--apply exits non-zero when a cache cannot be deleted" [ "$rc" -ne 0 ]
  check "--apply warns about the cache it could not delete" grep -q "WARN.*alpha/node_modules" "$SB/perm-apply.log"
  check "--apply does not report the undeletable cache as deleted" \
    not_listed "DELETED .*alpha/node_modules" "$SB/perm-apply.log"
  check "--apply counts only what it deleted" \
    grep -q "合計: $(deleted_total "$SB/perm-apply.log") MB" "$SB/perm-apply.log"
fi

# Mutants: each removes one behavior; the check that pins it must fail.
# The old/new texts below are literal script source, so they must not expand.
# shellcheck disable=SC2016
if [ -z "${DEV_SCRIPT:-}" ]; then
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
    out=$(DEV_SCRIPT="$m" bash "$SELF" 2>&1)
    check "mutant $1 is caught by: $2" grep -qF "FAIL: $2" <<<"$out"
  }
  caught_by no-dirty-check "--apply keeps the cache of a worktree with an uncommitted edit" \
    'if [ -n "$work" ]; then rc=1; break; fi' ':'
  caught_by tracked-edits-filtered "--apply keeps a cache holding a tracked file with an uncommitted edit" \
    "UNTRACKED_CACHE_RE='^\\?\\? (.*/)?(" "UNTRACKED_CACHE_RE='^...(.*/)?("
  caught_by status-failure-ignored "--apply keeps the cache of a repository whose status cannot be read" \
    'if ! st=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null); then rc=1; break; fi' \
    'st=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null || true)'
  caught_by untracked-collapsed "dry-run lists the stale cache" \
    'status --porcelain --untracked-files=all' 'status --porcelain'
  caught_by head-only "--apply keeps the cache of an old checkout whose other branch has a recent commit" \
    'log -1 --all --format' 'log -1 --format'
  caught_by no-owning-root "--apply keeps an active repository's cache inside a plain folder" \
    'root=$(owning_root "$t" "$project")' 'root=$project'
  caught_by gate-on-top-level "--apply deletes a stale repository's cache inside an active one" \
    '  sweep "$dir" "$MAX_DEPTH" "$dir"' '  if is_stale "$dir" "$STALE_DAYS"; then sweep "$dir" "$MAX_DEPTH" "$dir"; fi'
  caught_by maxdepth-4 "--apply deletes a stale worktree's cache six levels down" \
    'MAX_DEPTH=7' 'MAX_DEPTH=4'
  caught_by no-recurse-into-target "--apply deletes a cache under a target/ that is not a build directory" \
    '      sweep "$t" $((depth - $(printf' '      continue; sweep "$t" $((depth - $(printf'
  caught_by du-stops-the-sweep "dry-run continues past an unreadable cache" \
    '{ du -sm "$t" 2>/dev/null || true; }' 'du -sm "$t" 2>/dev/null'
  caught_by rm-failure-hidden "--apply exits non-zero when a cache cannot be deleted" \
    'if rm -rf "$t"; then' 'if rm -rf "$t" || true; then'
  caught_by archive-ignores-nested "dry-run does not suggest archiving a folder with an active repository inside" \
    'if archivable "$dir" "$ARCHIVE_DAYS"; then' 'if is_stale "$dir" "$ARCHIVE_DAYS"; then'
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
