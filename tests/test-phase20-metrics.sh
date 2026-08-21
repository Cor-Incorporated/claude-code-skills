#!/usr/bin/env bash
# Phase 20 T20-3: falsifiable H2/H10 meters and structured ledger records.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/repo" "$SB/home"

export HOME="$SB/home"
export AIDD_LEDGER_SOURCE=test
export AIDD_LEDGER_SESSION=Phase20-Cursor
export AIDD_LEDGER_AGENT=cursor
export PATH="$SB/bin:$PATH"
LEDGER="$HOME/.claude/hooks/ledger/guard-ledger.jsonl"

pass=0
fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

cat >"$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_MODE:-metrics}" in
  api-error)
    echo "synthetic API failure" >&2
    exit 1
    ;;
  wip-pr-boundary|wip-worktree-above|wip-dirty-above|wip-local-boundary|wip-prunable)
    if [[ "$1 $2" == "pr list" ]]; then
      if [[ "$FAKE_MODE" == "wip-pr-boundary" ]]; then
        cat <<'JSON'
[{"number":1,"isDraft":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]},{"number":2,"isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"}]},{"number":3,"isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}]},{"number":4,"isDraft":false,"statusCheckRollup":[{"status":"IN_PROGRESS"}]},{"number":5,"isDraft":false,"statusCheckRollup":[]}]
JSON
      else
        printf '[{"number":1,"isDraft":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}]\n'
      fi
      exit 0
    fi
    ;;
  wip-ok)
    if [[ "$1 $2" == "pr list" ]]; then
      printf '[{"number":1,"isDraft":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}]\n'
      exit 0
    fi
    ;;
  metrics)
    if [[ "$1 $2" == "pr list" ]]; then
      cat <<'JSON'
[{"number":10,"mergedAt":"2026-08-20T10:16:58Z","additions":70,"deletions":30},{"number":11,"mergedAt":"2026-08-20T12:00:00Z","additions":40,"deletions":10},{"number":12,"mergedAt":"2026-08-21T00:16:58Z","additions":999,"deletions":1}]
JSON
      exit 0
    fi
    if [[ "$1 $2" == "pr view" ]]; then
      if [[ "$3" == "10" ]]; then
        cat <<'JSON'
{"commits":[{"messageHeadline":"feat: one","messageBody":"work\n\nAgent-Lane: cursor"},{"messageHeadline":"feat: two","messageBody":"Agent-Lane: codex"},{"messageHeadline":"feat: three","messageBody":"Agent-Lane: opencode"},{"messageHeadline":"fix: invalid","messageBody":"Agent-Lane: bogus"}]}
JSON
      else
        cat <<'JSON'
{"commits":[{"messageHeadline":"feat: four","messageBody":"Agent-Lane: claude-code"},{"messageHeadline":"fix: duplicate","messageBody":"Agent-Lane: claude-code\nAgent-Lane: cursor"}]}
JSON
      fi
      exit 0
    fi
    if [[ "$1 $2" == "issue list" ]]; then
      cat <<'JSON'
[{"number":1,"createdAt":"2026-08-20T10:16:58Z","closedAt":null},{"number":2,"createdAt":"2026-08-20T11:00:00Z","closedAt":"2026-08-20T12:00:00Z"},{"number":3,"createdAt":"2026-08-21T00:16:58Z","closedAt":"2026-08-21T00:16:58Z"}]
JSON
      exit 0
    fi
    if [[ "$1 $2" == "run list" ]]; then
      cat <<'JSON'
[{"databaseId":1,"createdAt":"2026-08-20T10:16:58Z","conclusion":"success","status":"completed"},{"databaseId":2,"createdAt":"2026-08-20T13:00:00Z","conclusion":"failure","status":"completed"},{"databaseId":3,"createdAt":"2026-08-21T00:16:58Z","conclusion":"success","status":"completed"}]
JSON
      exit 0
    fi
    ;;
esac
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
chmod +x "$SB/bin/gh"

cat >"$SB/bin/git" <<'EOF'
#!/usr/bin/env bash
mode="${FAKE_MODE:-wip-ok}"
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  if [[ "$mode" == "wip-prunable" ]]; then
    printf 'worktree %s/wt-1\nHEAD deadbeef\nbranch refs/heads/test-1\n\n' "${FAKE_ROOT:?}"
    printf 'worktree %s/wt-2\nHEAD deadbeef\nbranch refs/heads/test-2\n\n' "${FAKE_ROOT:?}"
    printf 'worktree %s/stale\nHEAD deadbeef\nprunable gitdir file points to non-existent location\n\n' "${FAKE_ROOT:?}"
    exit 0
  fi
  count=2
  case "$mode" in
    wip-pr-boundary|wip-dirty-above|wip-local-boundary) count=63 ;;
    wip-worktree-above) count=64 ;;
  esac
  i=1
  while [[ "$i" -le "$count" ]]; do
    printf 'worktree %s/wt-%s\nHEAD deadbeef\nbranch refs/heads/test-%s\n\n' "${FAKE_ROOT:?}" "$i" "$i"
    i=$((i + 1))
  done
  exit 0
fi
if [[ "$*" == *"status --porcelain"* ]]; then
  if [[ "$mode" == "wip-prunable" && "$*" == *"/stale"* ]]; then
    echo "fatal: not a git repository" >&2
    exit 1
  fi
  if [[ "$mode" == "wip-pr-boundary" || "$mode" == "wip-local-boundary" || "$mode" == "wip-worktree-above" || "$mode" == "wip-dirty-above" ]]; then
    path=""
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "-C" ]] && path="$arg"
      prev="$arg"
    done
    n="${path##*-}"
    dirty_limit=7
    [[ "$mode" == "wip-dirty-above" ]] && dirty_limit=8
    [[ "$n" -le "$dirty_limit" ]] && printf ' M file-%s\n' "$n"
  fi
  exit 0
fi
echo "unexpected git invocation: $*" >&2
exit 1
EOF
chmod +x "$SB/bin/git"
export FAKE_ROOT="$SB"

# Structured ledger: nested/long fields survive, attribution is forced, and bad
# input returns non-zero rather than being rounded to success.
LONG="$(python3 -c 'print("x" * 500)')"
if (
  . "$ROOT/hooks/lib/aidd-ledger.sh"
  aidd_ledger_append "legacy-probe" "warn" "warn" "legacy command" "legacy-rule"
  aidd_ledger_append_record "{\"component\":\"H2\",\"event\":\"measure\",\"detail\":{\"long\":\"$LONG\"},\"source\":\"forged\"}"
); then
  ok "legacy and structured ledger appends coexist"
else
  bad "legacy or structured ledger append failed"
fi
if python3 - "$LEDGER" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
legacy, row = rows[:2]
assert legacy["hook"] == "legacy-probe" and legacy["cmd_head"] == "legacy command"
assert len(row["detail"]["long"]) == 500
assert (row["source"], row["session"], row["agent"]) == ("test", "Phase20-Cursor", "cursor")
PY
then ok "legacy row stays intact; structured JSON is untruncated and attributed"; else bad "ledger compatibility or structured record mismatch"; fi
if (
  . "$ROOT/hooks/lib/aidd-ledger.sh"
  aidd_ledger_append_record '[]'
) >/dev/null 2>&1; then bad "structured ledger accepted a non-object"; else ok "structured ledger rejects a non-object"; fi
printf 'not a directory\n' >"$SB/ledger-parent"
if (
  export AIDD_LEDGER_PATH="$SB/ledger-parent/ledger.jsonl"
  . "$ROOT/hooks/lib/aidd-ledger.sh"
  aidd_ledger_append_record '{"component":"H2","event":"measure"}'
) >/dev/null 2>&1; then bad "structured ledger hid an append failure"; else ok "structured ledger returns append failures"; fi

export FAKE_MODE=wip-pr-boundary
WIP_OUT="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if python3 - "$WIP_OUT" <<'PY'
import json, sys
r=json.loads(sys.argv[1]); d=r["detail"]
assert r["event"] == "warn"
assert (d["review_ready_open_prs"], d["worktrees"], d["dirty_worktrees"]) == (2,63,7)
assert d["active_lanes"] is None
PY
then ok "H2 warns at the PR threshold and ignores failed/pending/missing checks"; else bad "H2 PR boundary mismatch"; fi

export FAKE_MODE=wip-local-boundary
WIP_BOUNDARY="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if [[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["event"])' "$WIP_BOUNDARY")" == measure ]]; then
  ok "H2 worktree=63 and dirty=7 remain below the above-threshold warning"
else
  bad "H2 local boundary produced a false warning"
fi

export FAKE_MODE=wip-worktree-above
WIP_WORKTREE="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["event"]=="warn" and r["detail"]["warn_reasons"]==["worktrees"]' "$WIP_WORKTREE"; then
  ok "H2 worktree=64 warns independently"
else
  bad "H2 worktree above-threshold axis mismatch"
fi

export FAKE_MODE=wip-dirty-above
WIP_DIRTY="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["event"]=="warn" and r["detail"]["warn_reasons"]==["dirty_worktrees"]' "$WIP_DIRTY"; then
  ok "H2 dirty=8 warns independently"
else
  bad "H2 dirty above-threshold axis mismatch"
fi

export FAKE_MODE=wip-ok
WIP_OK="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if [[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["event"])' "$WIP_OK")" == measure ]]; then
  ok "H2 below thresholds records measure"
else
  bad "H2 below thresholds did not record measure"
fi

export FAKE_MODE=wip-prunable
WIP_PRUNABLE="$(bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test)"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1])["detail"]; assert (d["worktrees"],d["dirty_worktrees"],d["prunable_worktrees_skipped"])==(2,0,1)' "$WIP_PRUNABLE"; then
  ok "H2 skips one prunable worktree and reports the skipped count"
else
  bad "H2 prunable worktree axis mismatch"
fi

export FAKE_MODE=api-error
if bash "$ROOT/scripts/wip-inventory.sh" --repo="$SB/repo" --github=Cor/Test >"$SB/error.json" 2>/dev/null; then
  bad "H2 API failure returned success"
elif [[ "$(python3 - "$SB/error.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["event"])
PY
)" == error ]]; then
  ok "H2 API failure remains an ERROR row"
else
  bad "H2 API failure was not recorded"
fi

export FAKE_MODE=metrics
STAGE_OUT="$(bash "$ROOT/scripts/stage-landing.sh" --github=Cor/Test \
  --from=2026-08-20T10:16:58Z --to=2026-08-21T00:16:58Z --cd-workflow=v2-alpha-cd.yml)"
if python3 - "$STAGE_OUT" <<'PY'
import json, sys
r=json.loads(sys.argv[1]); a=r["detail"]["activity"]; l=r["detail"]["landing"]
assert (a["changed_lines"], a["commits"]) == (150,6)
for tool in ("claude-code","codex","cursor","opencode"):
    assert a["agent_lane"][tool] == {"commits":1,"prs":1}
assert a["agent_lane"]["unknown"] == {"commits":2,"prs":2}
assert (l["merged_prs"],l["issues_created"],l["issues_closed"],l["issues_open_net"]) == (2,2,1,1)
assert l["cd"] == {"workflow":"v2-alpha-cd.yml","success":1,"total":2,"rate":0.5}
assert l["issue_closeable_reached"] is None
PY
then ok "H10 enforces [from,to), separates activity/landing, and attributes exact trailers"; else bad "H10 fixture mismatch"; fi

if python3 - "$LEDGER" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding="utf-8")]
assert all(r["source"] == "test" and r["session"] == "Phase20-Cursor" for r in rows)
assert any(r["component"] == "H2" and r["event"] == "warn" for r in rows)
assert any(r["component"] == "H2" and r["event"] == "error" for r in rows)
assert any(r["component"] == "H10" and r["event"] == "measure" for r in rows)
PY
then ok "all synthetic rows remain source=test and session-attributed"; else bad "synthetic ledger attribution mismatch"; fi

printf '%s\n' "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
