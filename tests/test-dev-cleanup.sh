#!/usr/bin/env bash
# scripts/dev-cleanup.sh deletes build caches only with --apply, and only where the git repository
# that owns the cache (a main checkout with its linked worktrees, and for a submodule every superproject
# above it) has had no commit for 90+ days and has no uncommitted work. A directory outside git counts
# as stale only when every repository inside it is stale too. The accident this pins: deleting caches of
# work still in use — an active project, an active or dirty worktree inside an old repository (the
# <repo>/.worktrees/<agent>/<slug> layout of AGENTS.md), a linked worktree, an active repository inside a
# folder that is not a repository (its caches and the folder's own), a submodule of an active
# superproject, a repository with no commits yet, a dirty worktree whose path has a newline — or files
# that are not caches: tracked files (also under a path starting with ':'), git repositories inside a
# cache (also bare ones), and anything on another file system (a mount inside a cache, a volume mounted
# inside a project). It also pins caches that must be found: deep inside a worktree, inside a stale
# repository nested in an active one, under a target/ that is not a build directory, in the worktree of
# a bare repository, and in a repository whose git log prints signatures; that a failure neither stops
# the sweep nor is reported as freed; that nothing is deleted when the mount table cannot be read; that
# git status does not rewrite indexes; that a missing DEV_DIR or $HOME fails; and the 180-day archive
# threshold.
# The test writes mutants of the script and runs itself against each one (DEV_SCRIPT) to show that
# the check pinning each behavior fails without it.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# Keep the fixtures and the script away from the machine's git configuration.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/tests/$(basename "$0")"
SRC="$ROOT/scripts/dev-cleanup.sh"
SCRIPT="${DEV_SCRIPT:-$SRC}"
SB=$(mktemp -d) || exit 1
MOUNTED=""
cleanup() {
  [ -n "$MOUNTED" ] && hdiutil detach -quiet -force "$MOUNTED" >/dev/null 2>&1
  chmod -R u+rwx "$SB" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
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

# cache <dir> [name]: an 11 MB cache directory (the script ignores caches under 10 MB). The blob is
# random bytes (zeros may take no space on a compressing file system) hard-linked from one file, or
# copied where a hard link cannot reach (another file system).
BLOB="$SB/blob11"
dd if=/dev/urandom of="$BLOB" bs=1048576 count=11 2>/dev/null
cache() {
  mkdir -p "$1/${2:-node_modules}"
  ln -f "$BLOB" "$1/${2:-node_modules}/blob" 2>/dev/null || cp "$BLOB" "$1/${2:-node_modules}/blob"
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

# mount stub: the script reads mount points from `mount`. The stub reports FAKE_MOUNT_AT as a mounted
# share (it is an ordinary directory here) and fails when FAKE_MOUNT_FAIL is set.
mkdir -p "$SB/bin"
cat >"$SB/bin/mount" <<'EOF'
#!/bin/sh
[ -n "${FAKE_MOUNT_FAIL:-}" ] && exit 1
printf '%s\n' "/dev/disk1s1 on / (apfs, local, journaled)"
[ -n "${FAKE_MOUNT_AT:-}" ] && printf '%s\n' "//server/share on $FAKE_MOUNT_AT (smbfs, nodev, nosuid, mounted by test)"
exit 0
EOF
chmod +x "$SB/bin/mount"
export PATH="$SB/bin:$PATH"

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
# data/ keeps target/ and venv/ that are not build output; they are ignored, so not work
mkdir -p "$D/data"
printf 'target/\nvenv/\n' >"$D/data/.gitignore"
repo "$D/data" 100 .gitignore
cache "$D/data" target
cache "$D/data" venv
cache "$D/data/target/web"
# an old repository that commits a file under node_modules/ and has an uncommitted edit to it
repo "$D/trackedcache" 100 node_modules/patch.js
printf 'edited\n' >>"$D/trackedcache/node_modules/patch.js"
cache "$D/trackedcache" .next
# an old repository whose node_modules/ holds a git checkout committed 1 day ago
repo "$D/nestedgit" 100
repo "$D/nestedgit/node_modules/dep" 1
# an old repository with an untracked user file under target/ that is not a build directory
repo "$D/targetwork" 100
mkdir -p "$D/targetwork/target"
printf 'notes\n' >"$D/targetwork/target/notes.txt"
cache "$D/targetwork" .next
# an old repository that commits a file under node_modules/ and leaves it unchanged
repo "$D/trackedclean" 100 node_modules/source.js
# an old repository that ignores data/, with an active repository under data/target/
# (target/ there is not a build directory)
mkdir -p "$D/parentdata"
printf 'data/\n' >"$D/parentdata/.gitignore"
repo "$D/parentdata" 200 .gitignore
repo "$D/parentdata/data/target/inner" 1
# an old repository where git status fails (git log still works)
repo "$D/brokenstatus" 100
git -C "$D/brokenstatus" config status.showUntrackedFiles bogus
# an old repository with an active checkout inside packages/app/node_modules/
repo "$D/archnested" 200
repo "$D/archnested/packages/app/node_modules/dep" 1
# a folder outside git with an active checkout nine levels down
repo "$D/deepnested/a/b/c/d/e/f/g/h/inner" 1
# a clean repository idle for 200 days: the one git repository the archive suggestion must name
repo "$D/ancient" 200
# an old repository that commits a file under ":x/node_modules/" (a leading ":" is pathspec magic)
repo "$D/colon" 100
mkdir -p "$D/colon/:x/node_modules"
printf 'keep\n' >"$D/colon/:x/node_modules/keep.js"
g -C "$D/colon" --literal-pathspecs add -- ":x/node_modules/keep.js"
commit_at "$D/colon" 100
cache "$D/colon/:x"
# folders outside git with caches of their own: ws/ serves an active repository inside it, wsold/ only a
# stale one
cache "$D/ws"
cache "$D/ws" .venv
touch "$D/ws/.venv/pyvenv.cfg"
repo "$D/ws/app" 1
cache "$D/wsold"
repo "$D/wsold/app" 100
# submodules whose own history is 200 days old (node_modules/ is ignored inside them): one in an active
# superproject, one in a stale superproject
mkdir -p "$SB/sublib"
printf 'node_modules/\n' >"$SB/sublib/.gitignore"
git init -q "$SB/sublib"
commit_at "$SB/sublib" 200 .gitignore
for spec in superactive:1 superold:100; do
  sp=${spec%%:*}
  mkdir -p "$D/$sp"
  git init -q "$D/$sp"
  g -c protocol.file.allow=always -C "$D/$sp" submodule add -q "$SB/sublib" vendor/lib >/dev/null 2>&1
  commit_at "$D/$sp" "${spec#*:}"
  cache "$D/$sp/vendor/lib"
done
# an old bare repository with a clean worktree that holds a cache (git worktree list names the bare
# repository itself first, and git status fails there)
git init -q "$SB/baresrc"
commit_at "$SB/baresrc" 100 src.txt
git clone -q --bare "$SB/baresrc" "$D/bareproj/repo.git"
g -C "$D/bareproj/repo.git" worktree add -q "$D/bareproj/main" >/dev/null 2>&1
cache "$D/bareproj/main"
# an old repository whose worktree, with a newline in its path, holds an uncommitted edit
mkdir -p "$D/nlrepo"
ignore_worktrees "$D/nlrepo"
repo "$D/nlrepo" 100 .gitignore src.txt
NLWT="$D/nlrepo/.worktrees/claude/new"$'\n'"line"
g -C "$D/nlrepo" worktree add -q "$NLWT" -b nl
printf 'edited\n' >>"$NLWT/src.txt"
# an old repository whose node_modules/ holds a bare repository (a mirror: no .git anywhere)
repo "$D/nestedbare" 100
git init -q --bare "$D/nestedbare/node_modules/mirror.git"
# an old repository with a network share mounted inside its node_modules/ (the stub reports it)
repo "$D/mounted" 100
mkdir -p "$D/mounted/node_modules/share"
printf 'remote data\n' >"$D/mounted/node_modules/share/remote.txt"
FAKE_MOUNT_AT=$(cd "$D/mounted/node_modules/share" && pwd -P)
export FAKE_MOUNT_AT
# an old repository whose tracked file changed its mtime after the index was written: git status
# rewrites the index to refresh it unless optional locks are off
repo "$D/touched" 100 src.txt
touch -t 202001010000 "$D/touched/src.txt"
TOUCHED_INDEX=$(git -C "$D/touched" rev-parse --path-format=absolute --git-path index)
touched_before=$(cksum <"$TOUCHED_INDEX")

DEV_DIR="$D" bash "$SCRIPT" >"$SB/dry.log" 2>&1
rc=$?
check "dry-run exits 0" [ "$rc" -eq 0 ]
check "dry-run does not rewrite the index of a stale repository" [ "$touched_before" = "$(cksum <"$TOUCHED_INDEX")" ]
check "dry-run keeps the stale project's cache" [ -d "$D/stale/node_modules" ]
check "dry-run lists the stale cache" grep -q "candidate .*/stale/node_modules" "$SB/dry.log"
check "dry-run does not list the active cache" not_listed "/active/node_modules" "$SB/dry.log"
check "dry-run says why it keeps a cache with a mount point inside" \
  grep -q "KEEP (中にマウントポイントがある): .*/mounted/node_modules" "$SB/dry.log"
check "dry-run suggests archiving a clean git repository idle for 200 days" grep -q "ARCHIVE.*: ancient " "$SB/dry.log"
check "dry-run does not suggest archiving a repository idle for 100 days" not_listed "ARCHIVE.*: stale " "$SB/dry.log"

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
check "--apply keeps the other caches of a repository with a tracked edit under node_modules/" \
  [ -d "$D/trackedcache/.next" ]
check "--apply keeps the cache of a repository whose status cannot be read" [ -d "$D/brokenstatus/node_modules" ]
check "--apply keeps a cache that holds a tracked file" [ -f "$D/trackedclean/node_modules/source.js" ]
check "--apply keeps a cache that holds a git repository" [ -d "$D/nestedgit/node_modules/dep/.git" ]
check "--apply keeps the other caches of a repository with untracked work under a non-build target/" \
  [ -d "$D/targetwork/.next" ]
check "--apply keeps an active repository's cache under a non-build target/" \
  [ -d "$D/parentdata/data/target/inner/node_modules" ]
check "--apply does not suggest archiving the repository with no commits" \
  not_listed "ARCHIVE.*: unborn " "$SB/apply.log"
check "dry-run suggests archiving a folder outside git with no repository inside" \
  grep -q "ARCHIVE.*: plain " "$SB/dry.log"
check "dry-run does not suggest archiving a folder with an active repository inside" \
  not_listed "ARCHIVE.*: group " "$SB/dry.log"
check "dry-run does not suggest archiving a repository with an active one under a non-build target/" \
  not_listed "ARCHIVE.*: parentdata " "$SB/dry.log"
check "dry-run does not suggest archiving a repository with an active checkout inside node_modules/" \
  not_listed "ARCHIVE.*: archnested " "$SB/dry.log"
check "dry-run does not suggest archiving a folder with an active checkout nine levels down" \
  not_listed "ARCHIVE.*: deepnested " "$SB/dry.log"
check "--apply keeps a cache that holds an active checkout" [ -d "$D/archnested/packages/app/node_modules/dep/.git" ]
check "--apply keeps a cache holding a tracked file under a path starting with ':'" \
  [ -f "$D/colon/:x/node_modules/keep.js" ]
check "--apply keeps a folder's own node_modules/ while a repository inside it is active" [ -d "$D/ws/node_modules" ]
check "--apply keeps a folder's own .venv/ while a repository inside it is active" [ -d "$D/ws/.venv" ]
check "--apply deletes a folder's own cache when every repository inside it is stale" [ ! -e "$D/wsold/node_modules" ]
check "--apply keeps a submodule's cache while its superproject is active" \
  [ -d "$D/superactive/vendor/lib/node_modules" ]
check "--apply deletes a submodule's cache when it and its superproject are stale" \
  [ ! -e "$D/superold/vendor/lib/node_modules" ]
check "--apply deletes the cache of a stale bare repository's worktree" [ ! -e "$D/bareproj/main/node_modules" ]
check "--apply keeps the caches of a repository whose worktree with a newline in its path has an uncommitted edit" \
  [ -d "$D/nlrepo/node_modules" ]
check "--apply keeps a cache that holds a bare git repository" [ -f "$D/nestedbare/node_modules/mirror.git/HEAD" ]
check "--apply keeps a cache with a mount point inside" [ -f "$D/mounted/node_modules/share/remote.txt" ]
check "--apply deletes the cache of the repository whose index it did not rewrite" [ ! -e "$D/touched/node_modules" ]

# The caller's git environment must not redirect the checks to another repository.
V="$SB/envvars"
repo "$V/active" 1
repo "$V/old" 100
GIT_DIR="$V/old/.git" GIT_WORK_TREE="$V/old" DEV_DIR="$V" bash "$SCRIPT" --apply >"$SB/env.log" 2>&1
check "--apply ignores GIT_DIR inherited from the caller" [ -d "$V/active/node_modules" ]

# Config injected through the environment (GIT_CONFIG_COUNT) must not change the verdict either: this
# value makes every git status fail, so nothing would look stale.
V2="$SB/envconfig"
repo "$V2/old" 100
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles GIT_CONFIG_VALUE_0=bogus \
  DEV_DIR="$V2" bash "$SCRIPT" --apply >"$SB/envconfig.log" 2>&1
check "--apply ignores git config injected through GIT_CONFIG_COUNT" [ ! -e "$V2/old/node_modules" ]

# With no project at all, the unmatched glob must not become a project named "*".
mkdir -p "$SB/empty"
DEV_DIR="$SB/empty" bash "$SCRIPT" >"$SB/empty.log" 2>&1
rc=$?
check "an empty DEV_DIR exits 0" [ "$rc" -eq 0 ]
check "an empty DEV_DIR suggests nothing" not_listed "ARCHIVE" "$SB/empty.log"

# A missing DEV_DIR must fail rather than report 0 MB, and $HOME itself is refused. (The same line
# refuses /, but no test runs the script on / — a mutant would sweep the whole disk.)
DEV_DIR="$SB/no-such-dir" bash "$SCRIPT" >"$SB/missing.log" 2>&1
rc=$?
check "a missing DEV_DIR exits non-zero" [ "$rc" -ne 0 ]
check "a missing DEV_DIR says so" grep -q "DEV_DIR" "$SB/missing.log"
cache "$SB/fakehome/proj"
HOME="$SB/fakehome" DEV_DIR="$SB/fakehome" bash "$SCRIPT" --apply >"$SB/home.log" 2>&1
rc=$?
check "DEV_DIR equal to \$HOME is refused" [ "$rc" -ne 0 ]
check "DEV_DIR equal to \$HOME deletes nothing" [ -d "$SB/fakehome/proj/node_modules" ]

# When the mount table cannot be read, no cache can be checked for mounts, so nothing is deleted.
MF="$SB/mountfail"
repo "$MF/old" 100
FAKE_MOUNT_FAIL=1 DEV_DIR="$MF" bash "$SCRIPT" --apply >"$SB/mountfail.log" 2>&1
check "--apply deletes nothing when the mount table cannot be read" [ -d "$MF/old/node_modules" ]

# log.showSignature=true: git log prints the signature check ("No signature") before %ct. The arithmetic
# on that used to abort the sweep, so the project after it was never swept.
HAVE_SIGN=false
if command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -q -t ed25519 -N '' -f "$SB/signkey" </dev/null >/dev/null 2>&1; then
  HAVE_SIGN=true
  SG="$SB/signed"
  repo "$SG/a-signed" 100
  when=$(($(date +%s) - 100 * 86400))
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" \
    g -C "$SG/a-signed" -c gpg.format=ssh -c user.signingkey="$SB/signkey.pub" commit -q -S --allow-empty -m signed
  git -C "$SG/a-signed" config log.showSignature true
  repo "$SG/b-after" 100
  DEV_DIR="$SG" bash "$SCRIPT" --apply >"$SB/signed.log" 2>&1
  check "--apply sweeps the project after a repository whose git log prints a signature" [ ! -e "$SG/b-after/node_modules" ]
  check "--apply deletes the cache of a stale repository whose git log prints a signature" \
    [ ! -e "$SG/a-signed/node_modules" ]
else
  printf 'SKIP: signed-commit checks (ssh-keygen cannot make a key here)\n'
fi

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
  # gamma's own directory is read-only, so its cache cannot be removed from it
  repo "$E/gamma" 100
  chmod 555 "$E/gamma"
  # delta is a folder outside git that cannot be fully searched
  mkdir -p "$E/delta/locked"
  chmod 000 "$E/delta/locked"

  DEV_DIR="$E" bash "$SCRIPT" >"$SB/perm-dry.log" 2>&1
  rc=$?
  check "dry-run continues past an unreadable cache" grep -q "candidate .*/beta/node_modules" "$SB/perm-dry.log"
  check "dry-run does not suggest archiving a folder it cannot fully search" \
    not_listed "ARCHIVE.*: delta " "$SB/perm-dry.log"
  check "dry-run exits 0 when a cache cannot be fully inspected" [ "$rc" -eq 0 ]
  check "dry-run does not report caches as undeletable" not_listed "削除できなかった" "$SB/perm-dry.log"

  DEV_DIR="$E" bash "$SCRIPT" --apply >"$SB/perm-apply.log" 2>&1
  rc=$?
  check "--apply deletes the next project's cache" [ ! -e "$E/beta/node_modules" ]
  check "--apply keeps a cache it cannot fully inspect" [ -f "$E/alpha/node_modules/blob" ]
  check "--apply warns about a cache it cannot fully inspect" grep -q "WARN.*alpha/node_modules" "$SB/perm-apply.log"
  check "--apply exits non-zero when a cache cannot be deleted" [ "$rc" -ne 0 ]
  check "--apply warns about the cache it could not delete" grep -q "WARN.*gamma/node_modules" "$SB/perm-apply.log"
  check "--apply does not report the undeletable cache as deleted" \
    not_listed "DELETED .*gamma/node_modules" "$SB/perm-apply.log"
  check "--apply counts only what it deleted" \
    grep -q "合計: $(deleted_total "$SB/perm-apply.log") MB" "$SB/perm-apply.log"
fi

# A real mount (macOS: hdiutil). find must not descend into a volume mounted inside a project (-xdev):
# the cache on that volume is not the project's to delete. The mount stub above does not report this
# mount, so only -xdev protects it. Mounting takes seconds, so only the top-level run builds it; the
# mutant that removes -xdev from the sweep runs with DEV_REALMOUNT=1.
HAVE_MOUNT=false
if command -v hdiutil >/dev/null 2>&1; then
  HAVE_MOUNT=true
  if [ -z "${DEV_SCRIPT:-}" ] || [ -n "${DEV_REALMOUNT:-}" ]; then
    RMD="$SB/realmount"
    mkdir -p "$RMD/host/share"
    printf 'share/\n' >"$RMD/host/.gitignore"
    repo "$RMD/host" 100 .gitignore
    if hdiutil create -quiet -size 24m -fs HFS+ -volname dcleanup -layout NONE "$SB/vol.dmg" &&
      hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$RMD/host/share" "$SB/vol.dmg"; then
      MOUNTED="$RMD/host/share"
      cache "$MOUNTED/pkg"
      DEV_DIR="$RMD" bash "$SCRIPT" --apply >"$SB/realmount.log" 2>&1
      check "--apply does not look for caches on a volume mounted inside a project" [ -d "$MOUNTED/pkg/node_modules" ]
      check "--apply still deletes the project's own cache next to the mount" [ ! -e "$RMD/host/node_modules" ]
    else
      check "a disk image can be mounted for the -xdev check" false
    fi
  fi
else
  printf 'SKIP: real-mount check (no hdiutil)\n'
fi

# Mutants: each removes one behavior; the check that pins it must fail.
# The old/new texts below are literal script source, so they must not expand.
# shellcheck disable=SC2016
if [ -z "${DEV_SCRIPT:-}" ]; then
  # Each mutant run builds its own sandbox, so up to MUTANT_JOBS of them run at once; the verdicts are
  # checked after all of them finish (bash 3.2 has no `wait -n`, so it then waits for the whole batch).
  MUTANT_JOBS=${MUTANT_JOBS:-4}
  MUTANT_ENV=()
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
    env ${MUTANT_ENV[@]+"${MUTANT_ENV[@]}"} DEV_SCRIPT="$m" bash "$SELF" >"$SB/mutant-$1.out" 2>&1 &
    if [ "$(jobs -rp | wc -l)" -ge "$MUTANT_JOBS" ]; then
      wait -n 2>/dev/null || wait
    fi
  }
  caught_by no-dirty-check "--apply keeps the cache of a worktree with an uncommitted edit" \
    'if [ -n "$work" ]; then rc=1; break; fi' ':'
  caught_by tracked-edits-filtered "--apply keeps the other caches of a repository with a tracked edit under node_modules/" \
    "UNTRACKED_CACHE_RE='^\\?\\? (.*/)?(" "UNTRACKED_CACHE_RE='^...(.*/)?("
  caught_by status-failure-ignored "--apply keeps the cache of a repository whose status cannot be read" \
    'if ! st=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null); then rc=1; break; fi' \
    'st=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null || true)'
  caught_by untracked-collapsed "dry-run lists the stale cache" \
    'status --porcelain --untracked-files=all' 'status --porcelain'
  caught_by head-only "--apply keeps the cache of an old checkout whose other branch has a recent commit" \
    'log -1 --all --format' 'log -1 --format'
  # A plain folder that holds an active repository now keeps its own caches (folder_stale), so the
  # innermost repository deciding shows where a stale repository's cache must still go.
  caught_by no-owning-root "--apply deletes a stale repository's cache inside a plain folder" \
    'root=$(owning_root "$t" "$project")' 'root=$project'
  caught_by gate-on-top-level "--apply deletes a stale repository's cache inside an active one" \
    '  sweep "$dir" "$MAX_DEPTH" "$dir"' '  if is_stale "$dir" "$STALE_DAYS"; then sweep "$dir" "$MAX_DEPTH" "$dir"; fi'
  caught_by maxdepth-4 "--apply deletes a stale worktree's cache six levels down" \
    'MAX_DEPTH=7' 'MAX_DEPTH=4'
  caught_by no-recurse-into-target "--apply deletes a cache under a target/ that is not a build directory" \
    '      sweep "$t" $((depth - $(printf' '      continue; sweep "$t" $((depth - $(printf'
  caught_by nested-git-deleted "--apply keeps a cache that holds a git repository" \
    '    if [ -n "$nested" ]; then' '    if false; then'
  caught_by maybe-cache-filtered \
    "--apply keeps the other caches of a repository with untracked work under a non-build target/" \
    'looks_like_cache "$wt/${BASH_REMATCH[1]}"; then continue; fi' 'true; then continue; fi'
  # These rely on the permission fixtures, which root cannot build.
  if [ "$(id -u)" -ne 0 ]; then
    caught_by du-stops-the-sweep "dry-run continues past an unreadable cache" \
      '{ du -sxm "$t" 2>/dev/null || true; }' 'du -sxm "$t" 2>/dev/null'
    caught_by inspect-failure-ignored "--apply keeps a cache it cannot fully inspect" \
      ' -print -quit \) 2>/dev/null); then' ' -print -quit \) 2>/dev/null || true); then'
    caught_by rm-failure-hidden "--apply does not report the undeletable cache as deleted" \
      'if rm -rf "$t"; then' 'if rm -rf "$t" || true; then'
    caught_by dry-run-counts-failures "dry-run exits 0 when a cache cannot be fully inspected" \
      '  [ "$APPLY" = true ] && failed=$((failed + 1))' '  failed=$((failed + 1))'
  fi
  caught_by tracked-files-deleted "--apply keeps a cache that holds a tracked file" \
    '      [ -z "$tracked" ] || continue' '      :'
  caught_by archive-prunes-target \
    "dry-run does not suggest archiving a repository with an active one under a non-build target/" \
    'roots=$(find "$1" -xdev -mindepth 2 -name .git -print -prune 2>/dev/null)' \
    'roots=$(find "$1" -xdev -mindepth 2 \( -type d -name target -prune \) -o \( -name .git -print -prune \) 2>/dev/null)'
  caught_by archive-prunes-caches \
    "dry-run does not suggest archiving a repository with an active checkout inside node_modules/" \
    'roots=$(find "$1" -xdev -mindepth 2 -name .git -print -prune 2>/dev/null)' \
    'roots=$(find "$1" -xdev -mindepth 2 \( -type d -name node_modules -prune \) -o \( -name .git -print -prune \) 2>/dev/null)'
  caught_by archive-depth-limit "dry-run does not suggest archiving a folder with an active checkout nine levels down" \
    'roots=$(find "$1" -xdev -mindepth 2 -name .git -print -prune 2>/dev/null)' \
    'roots=$(find "$1" -xdev -mindepth 2 -maxdepth 7 -name .git -print -prune 2>/dev/null)'
  caught_by archive-ignores-nested "dry-run does not suggest archiving a folder with an active repository inside" \
    'if archivable "$dir" "$ARCHIVE_DAYS"; then' 'if is_stale "$dir" "$ARCHIVE_DAYS"; then'
  caught_by git-env-inherited "--apply ignores GIT_DIR inherited from the caller" \
    $'unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \\\n  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE\n' \
    $':\n'
  caught_by config-env-inherited "--apply ignores git config injected through GIT_CONFIG_COUNT" \
    'unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR' 'unset GIT_DIR'
  if [ "$(id -u)" -ne 0 ]; then
    caught_by archive-ignores-search-failure "dry-run does not suggest archiving a folder it cannot fully search" \
      '-name .git -print -prune 2>/dev/null) || return 1' '-name .git -print -prune 2>/dev/null) || true'
  fi
  caught_by literal-pathspec-dropped "--apply keeps a cache holding a tracked file under a path starting with ':'" \
    'git -C "$root" --literal-pathspecs ls-files' 'git -C "$root" ls-files'
  if $HAVE_SIGN; then
    caught_by no-signature-off "--apply deletes the cache of a stale repository whose git log prints a signature" \
      'git -C "$d" -c log.showSignature=false log' 'git -C "$d" log'
    caught_by no-signature-handling "--apply sweeps the project after a repository whose git log prints a signature" \
      $'  last=$(git -C "$d" -c log.showSignature=false log -1 --all --format=%ct 2>/dev/null) || last=""\n  case "$last" in \'\' | *[!0-9]*) last="" ;; esac\n' \
      $'  last=$(git -C "$d" log -1 --all --format=%ct 2>/dev/null) || last=""\n'
  fi
  caught_by folder-caches-always-stale "--apply keeps a folder's own node_modules/ while a repository inside it is active" \
    $'    folder_stale "$r" "$2"\n    return\n' $'    return 0\n'
  caught_by submodule-alone "--apply keeps a submodule's cache while its superproject is active" \
    '    sup=$(git -C "$r" rev-parse --show-superproject-working-tree 2>/dev/null) || return 1' '    return 0'
  caught_by mount-ignored "--apply keeps a cache with a mount point inside" \
    '    if mount_inside "$t"; then' '    if false; then'
  caught_by mount-failure-ignored "--apply deletes nothing when the mount table cannot be read" \
    $') ||\n  MOUNTS_OK=false' $') ||\n  true'
  caught_by optional-locks "dry-run does not rewrite the index of a stale repository" \
    $'export GIT_OPTIONAL_LOCKS=0\n' ''
  caught_by bare-entry-checked "--apply deletes the cache of a stale bare repository's worktree" \
    '      bare) bare=true ;;' '      bare) ;;'
  caught_by worktree-list-lines \
    "--apply keeps the caches of a repository whose worktree with a newline in its path has an uncommitted edit" \
    'worktree list --porcelain -z' 'worktree list --porcelain'
  caught_by bare-nested-deleted "--apply keeps a cache that holds a bare git repository" \
    '-name HEAD' '-name NO_SUCH_HEAD'
  caught_by dev-dir-unchecked "a missing DEV_DIR exits non-zero" \
    $'  echo "ERROR: DEV_DIR をディレクトリとして開けない: $DEV_DIR" >&2\n  exit 2\n' $'  DEV_REAL=$DEV_DIR\n'
  caught_by home-not-refused "DEV_DIR equal to \$HOME is refused" \
    'if [ "$DEV_REAL" = / ] || [ "$DEV_REAL" = "$HOME_REAL" ]; then' 'if [ "$DEV_REAL" = / ]; then'
  caught_by archive-days-90 "dry-run does not suggest archiving a repository idle for 100 days" \
    'ARCHIVE_DAYS=180' 'ARCHIVE_DAYS=90'
  caught_by memo-ignores-days "dry-run does not suggest archiving a repository idle for 100 days" \
    'key="$common|$days"' 'key="$common"'
  if $HAVE_MOUNT; then
    MUTANT_ENV=(DEV_REALMOUNT=1)
    caught_by sweep-crosses-mounts "--apply does not look for caches on a volume mounted inside a project" \
      'find "$start" -xdev -mindepth 1' 'find "$start" -mindepth 1'
    MUTANT_ENV=()
  fi
  wait
  for i in ${M_NAMES[@]+"${!M_NAMES[@]}"}; do
    check "mutant ${M_NAMES[$i]} is caught by: ${M_EXPECT[$i]}" \
      grep -qF "FAIL: ${M_EXPECT[$i]}" "$SB/mutant-${M_NAMES[$i]}.out"
  done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
