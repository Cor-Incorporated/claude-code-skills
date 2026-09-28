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
# DEV_SCRIPT points the checks at another copy of the script (e.g. a mutated one) so they can be
# shown to fail.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${DEV_SCRIPT:-$ROOT/scripts/dev-cleanup.sh}"
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
check "--apply keeps the cache of a worktree with an uncommitted edit" \
  [ -d "$D/wiprepo/.worktrees/claude/wip/node_modules" ]
check "--apply keeps the repository's own cache while its worktree has an uncommitted edit" \
  [ -d "$D/wiprepo/node_modules" ]
check "--apply keeps the cache of a repository with an uncommitted new file" [ -d "$D/newfile/node_modules" ]
check "--apply keeps the active parent's own cache" [ -d "$D/activeparent/node_modules" ]
check "--apply keeps a linked worktree's cache" [ -d "$D/linked/node_modules" ]
check "--apply keeps target/ without Cargo.toml or pom.xml" [ -d "$D/data/target" ]
check "--apply keeps venv/ without pyvenv.cfg" [ -d "$D/data/venv" ]
check "--apply does not suggest archiving the repository with no commits" \
  not_listed "ARCHIVE.*: unborn " "$SB/apply.log"

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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
