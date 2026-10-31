# shellcheck shell=bash
# Shared sandbox for the codex-parallel.sh tests: a throwaway HOME and git repo, and a fake `codex` on PATH.
# The fake ends in `exec codex-sleep …` (a copy of sleep) so the process the wrapper's watchdog looks for is named
# *codex*, as the real binary is (h1_kill_run matches the process name).
#
# FAKE_CODEX_MODE:
#   stdin  — print the real CLI's "Reading additional input from stdin..." line, then read stdin to EOF (cat)
#   idle   — never make a tool call: sleep FAKE_CODEX_SLEEP seconds
#   busy   — print one event a second for FAKE_CODEX_BUSY_SEC seconds, with no tool call
#   edit   — write FAKE_CODEX_FILE into the worktree (-C) and exit 0
# Sourced by tests/test-codex-*.sh. Needs ROOT set to the repository root.

codex_fixture_setup() {
    SB="$(mktemp -d)"
    trap 'rm -rf "$SB"' EXIT
    export HOME="$SB/home" AIDD_LEDGER_SOURCE=test AIDD_LEDGER_PATH="$SB/ledger.jsonl"
    mkdir -p "$HOME" "$SB/bin"
    # macOS kills a copy of the platform /bin/sleep (arm64e, rc 137), so prefer Homebrew's gsleep; Linux's sleep copies.
    cp "$(command -v gsleep 2>/dev/null || command -v sleep)" "$SB/bin/codex-sleep"
    CODEX_SLEEP_OK=0
    "$SB/bin/codex-sleep" 0 2>/dev/null && CODEX_SLEEP_OK=1
    cat >"$SB/bin/codex" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "exec" ] || { echo "codex-cli 0.165.0"; exit 0; }
shift
cwd="" out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -C) cwd="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "${FAKE_CODEX_MODE:-edit}" in
    stdin)
        echo "Reading additional input from stdin..."
        cat >/dev/null
        echo '{"type":"turn.completed"}'
        ;;
    idle)
        echo '{"type":"thread.started"}'
        exec "$(dirname "$0")/codex-sleep" "${FAKE_CODEX_SLEEP:-120}"
        ;;
    busy)
        # works without tool calls the hook can count: one event a second on stdout (the --json event log)
        for _ in $(seq "${FAKE_CODEX_BUSY_SEC:-8}"); do echo '{"type":"item.completed"}'; sleep 1; done
        ;;
    edit)
        printf '%s\n' "${FAKE_CODEX_CONTENT:-edited}" >"$cwd/${FAKE_CODEX_FILE:-codex-edit.txt}"
        ;;
esac
[ -n "$out" ] && echo "fake codex done" >"$out"
exit 0
FAKE
    chmod +x "$SB/bin/codex"
    export PATH="$SB/bin:$PATH"
    REPO="$SB/repo"
    git init -q -b develop "$REPO"
    git -C "$REPO" config user.email t@example.invalid
    git -C "$REPO" config user.name t
    echo base >"$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -q -m "chore: base"
    # The lane basepoint gate needs origin/<base>: a local bare repository stands in for it.
    git init -q --bare "$SB/origin.git"
    git -C "$REPO" remote add origin "$SB/origin.git"
    git -C "$REPO" push -q origin develop
    git -C "$REPO" fetch -q origin
    export CODEX_H1_STATE_DIR="$SB/h1" CODEX_OUTPUT="$SB/out.md" CODEX_EVENT_LOG="$SB/events.jsonl" \
        CODEX_SNAPSHOT_FILE="$SB/snapshot.txt" CODEX_SANDBOX=workspace-write CODEX_H1_BYPASS_TRUST=0 \
        LANE_BASEPOINT_ENFORCE=0 LANE_BASE=develop CODEX_TIMEOUT_SEC="${CODEX_TIMEOUT_SEC:-60}"
}

# codex_run <script> <branch> [stdin-source-cmd] — run the wrapper, print elapsed seconds on the last line.
codex_run() {
    local script="$1" branch="$2" feed="${3:-}" t0 t1
    t0="$(date +%s)"
    if [ -n "$feed" ]; then
        # process substitution, not a pipe: a pipeline would wait for the feeder too, and the wrapper's own
        # finish time is what is measured
        bash "$script" "$REPO" "$branch" "test task" >"$SB/run.log" 2>&1 < <(bash -c "$feed")
    else
        bash "$script" "$REPO" "$branch" "test task" >"$SB/run.log" 2>&1 </dev/null
    fi
    t1="$(date +%s)"
    echo $((t1 - t0))
}
