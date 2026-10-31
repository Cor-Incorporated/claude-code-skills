#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/codex-parallel.sh
# C1 (2026-10-31): `codex exec` must not wait on the wrapper's stdin.
#
# Origin: the second L1 launch (18:21) came from a background Bash whose stdin stayed open. Codex printed
# "Reading additional input from stdin..." and waited 2 h 18 m with 0 tool calls
# (fire-logs/codex-L1-20261031-launch2.log, 1,185 B). The prompt is an argument; stdin carries nothing.
#
# The wrapper is run with stdin fed by a pipe that stays open for 30 s (`sleep 30 |`), the same as an open
# background stdin. The fake codex reads stdin to EOF. With stdin closed it finishes at once; without, it waits for
# the pipe. The mutant (the `</dev/null` removed) must take ≥ 25 s.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/codex-parallel-fixture.sh
. "$ROOT/tests/lib/codex-parallel-fixture.sh"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

codex_fixture_setup
export FAKE_CODEX_MODE=stdin
real="$(codex_run "$ROOT/scripts/codex-parallel.sh" feat/stdin-real 'sleep 30')"
grep -q 'fake codex done' "$SB/out.md" 2>/dev/null && done_real=yes || done_real=no
[[ "$real" -lt 15 && "$done_real" == yes ]] && ok "C1 with an open stdin the run finishes in ${real}s (stdin is /dev/null)" \
  || bad "C1 stdin" "elapsed=${real}s finished=$done_real; $(tail -5 "$SB/run.log")"

MUT="$SB/codex-parallel-mutant.sh"
python3 - "$ROOT/scripts/codex-parallel.sh" "$MUT" <<'PY'
import pathlib, sys
src, dst = sys.argv[1:3]
text = pathlib.Path(src).read_text()
n = text.count(" </dev/null 2>&1 | tee")
if n != 2:
    raise SystemExit("mutation target not found (%d)" % n)
pathlib.Path(dst).write_text(text.replace(" </dev/null 2>&1 | tee", " 2>&1 | tee"))
PY
cp -R "$ROOT/scripts/lib" "$SB/lib"   # the mutant sources lib/ next to itself
if [[ -f "$MUT" ]]; then
  rm -f "$SB/out.md"
  mutant="$(codex_run "$MUT" feat/stdin-mutant 'sleep 30')"
  [[ "$mutant" -ge 25 ]] && ok "C1 mutant (stdin not closed) waits for the pipe: ${mutant}s vs ${real}s" \
    || bad "C1 mutant" "mutant finished in ${mutant}s — the test does not prove the stdin fix"
else
  bad "C1 mutant" "could not build the mutant"
fi

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
