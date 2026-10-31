#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: scripts/codex-parallel.sh
# C2 (2026-10-31, aidd-governance#235 P4 / ADR-017, claude-code-skills#466): a Codex run that makes no tool call is
# stopped by the wrapper's watchdog, and the launch log says the watchdog was alive and why it stopped.
#
# Measured cause: the second L1 run's state (h1-state/codex-parallel_feat_l1-practical-bench_2.json) had
# tool_calls 0 and model None. h1_check's idle-stall check sat behind `if not restricted`, and `restricted` needs the
# model the hook records on the first tool call, so a run with no tool call could never trip it.
#
# Cases: an idle fake codex is stopped with no-progress-from-start well before the outer timeout; the log carries the
# watchdog line and the summary names the stop; a relaunch of the same delegation is not killed by that stop. The
# mutant (the new check removed) runs to the outer timeout instead.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/codex-parallel-fixture.sh
. "$ROOT/tests/lib/codex-parallel-fixture.sh"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

export CODEX_TIMEOUT_SEC=30 CODEX_H1_POLL_SEC=1 CODEX_H1_START_IDLE_SEC=3
codex_fixture_setup
if [[ "$CODEX_SLEEP_OK" != 1 ]]; then
  echo "SKIP: no sleep binary that runs under another name here (install coreutils for gsleep on macOS)"
  echo "--- 0 passed, 0 failed, 1 skipped ---"
  exit 0
fi
export FAKE_CODEX_MODE=idle FAKE_CODEX_SLEEP=90
real="$(codex_run "$ROOT/scripts/codex-parallel.sh" feat/idle)"
[[ "$real" -lt 20 ]] && grep -q 'stop condition tripped (no-progress-from-start)' "$SB/run.log" \
  && ok "C2 an idle run is stopped by the watchdog in ${real}s (no-progress-from-start)" \
  || bad "C2 idle stop" "elapsed=${real}s; $(grep -E 'h1|H1' "$SB/run.log" | tail -4)"
grep -q 'H1 watchdog: alive pid' "$SB/run.log" && ok "C2 the launch log says the watchdog is alive" \
  || bad "C2 watchdog line" "$(grep -E 'H1' "$SB/run.log" | head -3)"
grep -q 'watchdog stop: no-progress-from-start' "$SB/run.log" && ok "C2 the H1 summary names the watchdog stop" \
  || bad "C2 summary" "$(grep -E '^.*H1:' "$SB/run.log" | tail -2)"

# A relaunch of the same delegation must not be killed by the previous start's stop.
export FAKE_CODEX_MODE=edit CODEX_REPLACE_WORKTREE=1
again="$(codex_run "$ROOT/scripts/codex-parallel.sh" feat/idle)"
grep -q 'Status:    SUCCESS' "$SB/run.log" && ! grep -q 'stop condition tripped' "$SB/run.log" \
  && ok "C2 a relaunch of the same delegation runs (${again}s), the old stop is cleared" \
  || bad "C2 relaunch" "elapsed=${again}s; $(grep -E 'tripped|Status' "$SB/run.log" | tail -3)"
unset CODEX_REPLACE_WORKTREE

# Mutant: the start-idle check removed → only the outer timeout (30 s) ends the run. The wrapper is copied next to
# the mutated library so it sources that one.
MUT="$SB/mut/codex-parallel.sh"
python3 - "$ROOT" "$MUT" <<'PY'
import pathlib, shutil, sys
root, mut = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
(mut.parent / "lib").mkdir(parents=True, exist_ok=True)
for f in (root / "scripts/lib").iterdir():
    if f.is_file():
        shutil.copy(f, mut.parent / "lib" / f.name)
lib = mut.parent / "lib/h1-runtime.sh"
text = lib.read_text()
needle = '    print("no-progress-from-start"); raise SystemExit(0)\n'
if needle not in text:
    raise SystemExit("mutation target not found")
lib.write_text(text.replace(needle, "    pass\n", 1))
shutil.copy(root / "scripts/codex-parallel.sh", mut)
PY
export FAKE_CODEX_MODE=idle
mutant="$(codex_run "$MUT" feat/idle-mutant)"
[[ "$mutant" -ge 25 ]] && ! grep -q 'stop condition tripped' "$SB/run.log" \
  && ok "C2 mutant (no start-idle check) runs to the outer timeout: ${mutant}s vs ${real}s" \
  || bad "C2 mutant" "mutant elapsed=${mutant}s — the test does not prove the check"

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
