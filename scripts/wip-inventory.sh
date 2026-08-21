#!/usr/bin/env bash
# H2 measurement: inventory review-ready work and local worktree pressure.
# This is a meter. Threshold warnings are recorded but never block the caller.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/hooks/lib/aidd-ledger.sh"

REPO_PATH="$(pwd)"
GITHUB_REPO=""
PR_WARN_THRESHOLD=2
WORKTREE_WARN_THRESHOLD=63
DIRTY_WARN_THRESHOLD=7

usage() {
  cat >&2 <<'EOF'
usage: wip-inventory.sh [--repo=PATH] [--github=OWNER/REPO]

Emits one JSON line and appends the same H2 measurement to the defense ledger.
Warnings are non-blocking (exit 0). Collection or ledger errors return exit 1.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --repo=*) REPO_PATH="${arg#*=}" ;;
    --github=*) GITHUB_REPO="${arg#*=}" ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; usage; exit 2 ;;
  esac
done

emit_error() {
  local message="$1" record
  record="$(python3 - "$GITHUB_REPO" "$message" <<'PY'
import json, sys
print(json.dumps({
    "component": "H2",
    "event": "error",
    "repo": sys.argv[1] or None,
    "subject": {"kind": "wip_inventory"},
    "detail": {"error": sys.argv[2], "active_lanes": None},
    "label": "collection-error",
}, ensure_ascii=False, separators=(",", ":")))
PY
)"
  printf '%s\n' "$record"
  aidd_ledger_append_record "$record" || true
  exit 1
}

[[ -d "$REPO_PATH" ]] || emit_error "repository path does not exist: $REPO_PATH"
if [[ -z "$GITHUB_REPO" ]]; then
  GITHUB_REPO="$(cd "$REPO_PATH" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || emit_error "cannot resolve GitHub repository for $REPO_PATH"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! gh pr list --repo "$GITHUB_REPO" --state open --limit 1000 \
  --json number,isDraft,statusCheckRollup >"$TMP_DIR/prs.json" 2>"$TMP_DIR/gh.err"; then
  emit_error "gh pr list failed: $(tr '\n' ' ' <"$TMP_DIR/gh.err")"
fi
python3 - "$TMP_DIR/prs.json" <<'PY' || emit_error "open PR collection reached the 1000-item safety cap"
import json, sys
if len(json.load(open(sys.argv[1], encoding="utf-8"))) >= 1000:
    raise SystemExit(1)
PY

if ! git -C "$REPO_PATH" worktree list --porcelain >"$TMP_DIR/worktrees.txt" 2>"$TMP_DIR/git.err"; then
  emit_error "git worktree list failed: $(tr '\n' ' ' <"$TMP_DIR/git.err")"
fi

grep '^worktree ' "$TMP_DIR/worktrees.txt" | sed 's/^worktree //' >"$TMP_DIR/paths.txt" || true
WORKTREE_COUNT="$(wc -l <"$TMP_DIR/paths.txt" | tr -d ' ')"
DIRTY_COUNT=0
while IFS= read -r worktree; do
  [[ -n "$worktree" ]] || continue
  if ! STATUS="$(git -C "$worktree" status --porcelain --untracked-files=normal 2>"$TMP_DIR/status.err")"; then
    emit_error "git status failed for worktree $worktree: $(tr '\n' ' ' <"$TMP_DIR/status.err")"
  fi
  if [[ -n "$STATUS" ]]; then
    DIRTY_COUNT=$((DIRTY_COUNT + 1))
  fi
done <"$TMP_DIR/paths.txt"

PR_COUNT="$(python3 - "$TMP_DIR/prs.json" <<'PY'
import json, sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
good = {"SUCCESS", "NEUTRAL", "SKIPPED"}

def green(pr):
    checks = pr.get("statusCheckRollup") or []
    if not checks:
        return False
    states = []
    for check in checks:
        state = check.get("conclusion") or check.get("state") or check.get("status")
        states.append((state or "").upper())
    return bool(states) and all(state in good for state in states)

print(sum(1 for pr in rows if green(pr)))
PY
)" || emit_error "cannot classify open PR checks"

EVENT="measure"
WARN_REASONS=""
if (( PR_COUNT >= PR_WARN_THRESHOLD )); then
  EVENT="warn"
  WARN_REASONS="review_ready_prs"
fi
if (( WORKTREE_COUNT > WORKTREE_WARN_THRESHOLD )); then
  EVENT="warn"
  WARN_REASONS="${WARN_REASONS:+${WARN_REASONS},}worktrees"
fi
if (( DIRTY_COUNT > DIRTY_WARN_THRESHOLD )); then
  EVENT="warn"
  WARN_REASONS="${WARN_REASONS:+${WARN_REASONS},}dirty_worktrees"
fi

RECORD="$(python3 - "$GITHUB_REPO" "$EVENT" "$PR_COUNT" "$WORKTREE_COUNT" "$DIRTY_COUNT" "$WARN_REASONS" <<'PY'
import json, sys
repo, event, prs, worktrees, dirty, reasons = sys.argv[1:]
record = {
    "component": "H2",
    "event": event,
    "repo": repo,
    "subject": {"kind": "wip_inventory"},
    "detail": {
        "review_ready_open_prs": int(prs),
        "worktrees": int(worktrees),
        "dirty_worktrees": int(dirty),
        "active_lanes": None,
        "thresholds": {
            "review_ready_open_prs_warn_at": 2,
            "worktrees_warn_above": 63,
            "dirty_worktrees_warn_above": 7,
        },
        "warn_reasons": [value for value in reasons.split(",") if value],
    },
    "label": "wip-pressure" if event == "warn" else "wip-baseline",
}
print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
PY
)"

printf '%s\n' "$RECORD"
aidd_ledger_append_record "$RECORD"
