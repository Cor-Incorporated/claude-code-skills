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
# MEASURED 2026-09-25 -- the gate does not run in the fixture. It resolves ROOT
# from its own path, so the fetch / rev-parse / diff it issues run in the checkout
# that contains this file (3 of 3 runs, traced with a git wrapper on PATH); the
# fixture only sees this file's own rev-parse. Cases 1-4 therefore do not observe
# the gate, and the standing invariant above does not hold yet. Running the gate
# inside $SB changes what these cases exercise, so it is left to a separate change.
#
# The fixtures are throwaway clones under $TMPDIR, and the gate's ledger, HOME and
# gh are confined to $SB (case 5). The origin is addressed as file:// because git
# ignores --depth for a plain local path. The base branch is named `trunk`, not `main`, so the local
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

# --- keep the gate's side effects inside $SB ---
# Measured 2026-09-25: every gate run below fell back to the default ledger
# ($HOME/.claude/hooks/ledger/guard-ledger.jsonl) because neither H5_LEDGER_PATH
# nor a PR body was set, and appended a real block row -- 3 rows per run of this
# file. `gh pr view 0` also went to the network. The runs now get a sandbox
# ledger, a sandbox HOME (so a fallback write lands in $SB, where case 5 can see
# it) and a gh stub. None of this changes what cases 1-4 assert.
export H5_LEDGER_PATH="$SB/ledger.jsonl"
# GitHub Actions sets GITHUB_EVENT_PATH in every job, and the gate reads the PR
# body from it before asking gh. Inherited, it made the gate read this PR's real
# body instead of the stub's (PR #397's first CI run: case 5 saw 0 rows).
# H5_PR_BODY would do the same, and H5_DIFF_FILES would skip the fetch these
# cases exist for.
unset GITHUB_EVENT_PATH H5_PR_BODY H5_DIFF_FILES
mkdir -p "$SB/bin" "$SB/home"
# The stub answers the gate's body lookup for H5_PR_NUMBER=0. The body carries a
# meta-filter word, so every gate run appends one evidence-filter measure row and
# case 5 has a write to look for, whatever the checkout's HEAD~1 diff is.
cat >"$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${1-}" == pr && "${2-}" == view ]] || exit 1
printf '%s\n' 'expect red (fixture body for tests/test-h5-no-shallow.sh)'
STUB
chmod +x "$SB/bin/gh"
# GIT_TERMINAL_PROMPT=0: without the real HOME there is no global credential
# helper, and a fetch must fail rather than wait for a password.
run_gate() {
  HOME="$SB/home" PATH="$SB/bin:$PATH" GIT_TERMINAL_PROMPT=0 \
    H5_BASE_REF=origin/trunk H5_HEAD_REF=HEAD H5_PR_NUMBER=0 \
    bash "$CHECK" >/dev/null 2>&1
}
# Lines in <file> (matching <ERE> when given); 0 when the file does not exist.
count_rows() {
  [[ -f "$1" ]] || { echo 0; return; }
  awk -v re="${2-}" 're == "" || $0 ~ re { n++ } END { print n + 0 }' "$1"
}

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
run_gate

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
run_gate
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
  run_gate
  [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]
) && ok "case4 an already-shallow clone is left shallow and the gate still runs" \
   || bad "case4 shallow clone path regressed" "see above"

# --- case 5: the gate wrote only inside $SB ---
# Each of the 3 runs appends one evidence-filter row (see the gh stub). A row in
# the default ledger under the gate's HOME means a run fell back to
# $HOME/.claude/hooks/ledger/guard-ledger.jsonl -- the user's real ledger when
# this file ran without a sandbox HOME.
fallback_rows="$(count_rows "$SB/home/.claude/hooks/ledger/guard-ledger.jsonl")"
sandbox_rows="$(count_rows "${H5_LEDGER_PATH-}" '"rule":"evidence-filter"')"
if [[ "$fallback_rows" -eq 0 && "$sandbox_rows" -eq 3 ]]; then
  ok "case5 all 3 gate runs wrote to the sandbox ledger, none to \$HOME (sandbox=$sandbox_rows fallback=$fallback_rows)"
else
  bad "case5 the gate wrote outside the sandbox ledger" \
      "default ledger under HOME: $fallback_rows rows (want 0); sandbox evidence-filter rows: $sandbox_rows (want 3)"
fi

echo "--- $PASS passed, $FAIL failed ---"
[[ "$FAIL" -eq 0 ]]
