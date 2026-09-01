#!/usr/bin/env bash
# aidd-governance#89: the verifier must not damage the repository it verifies.
#
# `git fetch --depth=1` can write .git/shallow and truncate the LOCAL repository,
# not just the fetch, after which merge-base against the base ref fails. Grift hit
# this on 2026-08-27: PR #2140 reported "refusing to merge unrelated histories",
# and Grift shipped the guarded fetch this file's fix is ported from (eb6df7415).
#
# HONEST LIMIT — read before trusting this file.
# These are INVARIANT assertions, not a reproduction. On 2026-09-02 the historical
# failure could NOT be reproduced on this machine in the shape the gate actually
# runs (clone -> feature branch -> commit -> gate): the unconditional `--depth=1`
# ran and the clone stayed full. Shallowing was only observed fetching directly
# into a fresh clone with no local commits. So restoring the defect does NOT turn
# these cases red here, and they must not be cited as evidence that the fix works.
# What they do give is a standing invariant: if any future change makes the gate
# truncate history or break merge-base, these fail. Treat that as the value, and
# treat the fix itself as "ported from a repo that measured the failure".
#
# Everything runs against a throwaway clone under $TMPDIR; no real repository is
# touched. The origin is addressed as file:// because git ignores --depth for a
# plain local path. The base branch is named `trunk`, not `main`, so the local
# push guard does not fire on the fixture.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/h5-admission-check.sh"
export AIDD_LEDGER_SOURCE=test

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; echo "  $2"; FAIL=$((FAIL + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# --- a small origin with real history, plus a full clone of it ---
git init -q --bare "$SB/origin.git"
git init -q "$SB/seed"
(
  cd "$SB/seed" || exit 1
  git config user.email t@example.com
  git config user.name t
  for n in 1 2 3 4 5; do
    printf 'commit %s\n' "$n" > file.txt
    git add file.txt
    git commit -q -m "commit $n"
  done
  git branch -M trunk
  git remote add origin "file://$SB/origin.git"
  git push -q origin trunk
) || { echo "seed setup failed"; exit 1; }

git clone -q -b trunk "file://$SB/origin.git" "$SB/work"
cd "$SB/work" || exit 1
git config user.email t@example.com
git config user.name t
git checkout -q -b feature
printf 'feature\n' > added.txt
git add added.txt
git commit -q -m "feature commit"

depth_before="$(git rev-list --count HEAD)"

# --- case 1: running the gate must not shallow a full clone ---
H5_BASE_REF=origin/trunk H5_HEAD_REF=HEAD H5_PR_NUMBER=0 \
  bash "$CHECK" >/dev/null 2>&1

shallow="$(git rev-parse --is-shallow-repository 2>/dev/null)"
depth_after="$(git rev-list --count HEAD)"
if [[ "$shallow" == "false" && ! -f .git/shallow && "$depth_after" == "$depth_before" ]]; then
  ok "case1 full clone stays full (is-shallow=$shallow, commits $depth_before -> $depth_after)"
else
  bad "case1 the gate shallowed the repository it was checking" \
      "is-shallow=$shallow shallowfile=$([ -f .git/shallow ] && echo yes || echo no) commits $depth_before -> $depth_after"
fi

# --- case 2: merge-base must still resolve afterwards ---
# This is what actually breaks downstream: a shallow repo cannot find the base.
if git merge-base origin/trunk HEAD >/dev/null 2>&1; then
  ok "case2 merge-base against the base ref still resolves"
else
  bad "case2 merge-base broke after running the gate" "$(git merge-base origin/trunk HEAD 2>&1)"
fi

# --- case 3: the gate is idempotent -- running it twice changes nothing ---
H5_BASE_REF=origin/trunk H5_HEAD_REF=HEAD H5_PR_NUMBER=0 \
  bash "$CHECK" >/dev/null 2>&1
depth_twice="$(git rev-list --count HEAD)"
if [[ "$depth_twice" == "$depth_before" ]] && git merge-base origin/trunk HEAD >/dev/null 2>&1; then
  ok "case3 second run is idempotent (commits still $depth_twice)"
else
  bad "case3 repository changed on the second run" "commits $depth_before -> $depth_twice"
fi

# --- case 4: an already-shallow clone (the CI shape) must still work ---
git clone -q --depth=1 -b trunk "file://$SB/origin.git" "$SB/shallow"
(
  cd "$SB/shallow" || exit 1
  git config user.email t@example.com
  git config user.name t
  git checkout -q -b feature
  printf 'x\n' > added.txt
  git add added.txt
  git commit -q -m "feature"
  H5_BASE_REF=origin/trunk H5_HEAD_REF=HEAD H5_PR_NUMBER=0 bash "$CHECK" >/dev/null 2>&1
  [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]
) && ok "case4 an already-shallow clone is left shallow and the gate still runs" \
   || bad "case4 shallow clone path regressed" "see above"

echo "--- $PASS passed, $FAIL failed ---"
[[ "$FAIL" -eq 0 ]]
