#!/usr/bin/env bash
# scripts/dev-cleanup.sh deletes build caches only in projects whose last commit is 90+ days old,
# and only with --apply. The accident this pins: deleting the caches of a project still in use.
# DEV_SCRIPT points the checks at another copy of the script (e.g. a mutated one) so they can be
# shown to fail.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${DEV_SCRIPT:-$ROOT/scripts/dev-cleanup.sh}"
SB=$(mktemp -d)
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

not_listed() {
  ! grep -q "$1" "$2"
}

# cache <dir>: an 11 MB node_modules (the script ignores caches under 10 MB)
cache() {
  mkdir -p "$1/node_modules"
  dd if=/dev/zero of="$1/node_modules/blob" bs=1048576 count=11 2>/dev/null
}

# project <name> <days since the last commit>
project() {
  local dir="$SB/dev/$1" when
  when=$(($(date +%s) - $2 * 86400))
  cache "$dir"
  git -C "$dir" init -q
  GIT_AUTHOR_DATE="@$when" GIT_COMMITTER_DATE="@$when" \
    git -C "$dir" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
}

project active 1
project stale 100
cache "$SB/dev/_archive/old"

DEV_DIR="$SB/dev" bash "$SCRIPT" >"$SB/dry.log" 2>&1
rc=$?
check "dry-run exits 0" [ "$rc" -eq 0 ]
check "dry-run keeps the stale project's cache" [ -d "$SB/dev/stale/node_modules" ]
check "dry-run keeps the active project's cache" [ -d "$SB/dev/active/node_modules" ]
check "dry-run lists the stale cache" grep -q "candidate .*/stale/node_modules" "$SB/dry.log"
check "dry-run does not list the active cache" not_listed "/active/node_modules" "$SB/dry.log"

DEV_DIR="$SB/dev" bash "$SCRIPT" --apply >"$SB/apply.log" 2>&1
rc=$?
check "--apply exits 0" [ "$rc" -eq 0 ]
check "--apply deletes the stale project's cache" [ ! -e "$SB/dev/stale/node_modules" ]
check "--apply keeps the active project's cache" [ -d "$SB/dev/active/node_modules" ]
check "--apply skips _archive" [ -d "$SB/dev/_archive/old/node_modules" ]

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
