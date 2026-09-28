#!/usr/bin/env bash
# scripts/dev-cleanup.sh deletes build caches only with --apply, and only where the git repository
# that owns the cache has had no commit for 90+ days. Directories outside git count as stale by
# design. The accident this pins: deleting caches of work still in use — an active project, an
# active worktree inside an old repository (the <repo>/.worktrees/<agent>/<slug> layout of
# AGENTS.md), a linked worktree, an active repository inside a folder that is not a repository,
# or a repository with no commits yet — and a failure that stops the sweep or is reported as freed.
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

g() {
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c user.name=test -c user.email=test@example.com "$@"
}

# cache <dir> [name]: an 11 MB cache directory (the script ignores caches under 10 MB)
cache() {
  mkdir -p "$1/${2:-node_modules}"
  dd if=/dev/zero of="$1/${2:-node_modules}/blob" bs=1048576 count=11 2>/dev/null
}

# commit_at <repo or worktree> <days ago>
commit_at() {
  local when
  when=$(($(date +%s) - $2 * 86400))
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" g -C "$1" commit -q --allow-empty -m "c$2"
}

# repo <dir> <days since the last commit>: a git repository with a cache
repo() {
  cache "$1"
  git init -q "$1"
  commit_at "$1" "$2"
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
repo "$D/oldrepo" 200
g -C "$D/oldrepo" worktree add -q "$D/oldrepo/.worktrees/claude/feat" -b feat
commit_at "$D/oldrepo/.worktrees/claude/feat" 1
cache "$D/oldrepo/.worktrees/claude/feat"
g -C "$D/active" worktree add -q "$D/linked" -b linked
commit_at "$D/linked" 1
cache "$D/linked"
repo "$D/rust" 100
cache "$D/rust" target
touch "$D/rust/Cargo.toml"
repo "$D/py" 100
cache "$D/py" .venv
touch "$D/py/.venv/pyvenv.cfg"
repo "$D/data" 100
cache "$D/data" target
cache "$D/data" venv

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
  check "--apply reports the cache it could not delete" grep -q "alpha/node_modules" "$SB/perm-apply.log"
  check "--apply counts only what it deleted" grep -q "合計: 11 MB" "$SB/perm-apply.log"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
