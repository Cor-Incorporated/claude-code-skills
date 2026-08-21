#!/usr/bin/env bash
# H10 measurement: separate activity volume from landed outcomes in [from,to).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/hooks/lib/aidd-ledger.sh"

GITHUB_REPO=""
FROM=""
TO=""
CD_WORKFLOW="v2-alpha-cd.yml"
COLLECTION_CAP=1000

usage() {
  cat >&2 <<'EOF'
usage: stage-landing.sh --github=OWNER/REPO --from=ISO8601 --to=ISO8601 [--cd-workflow=FILE]

The interval is start-inclusive and end-exclusive: [from,to).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --github=*) GITHUB_REPO="${arg#*=}" ;;
    --from=*) FROM="${arg#*=}" ;;
    --to=*) TO="${arg#*=}" ;;
    --cd-workflow=*) CD_WORKFLOW="${arg#*=}" ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; usage; exit 2 ;;
  esac
done
if [[ -z "$GITHUB_REPO" || -z "$FROM" || -z "$TO" ]]; then
  usage
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

emit_error() {
  local message="$1" record
  record="$(python3 - "$GITHUB_REPO" "$FROM" "$TO" "$message" <<'PY'
import json, sys
print(json.dumps({
    "component": "H10",
    "event": "error",
    "repo": sys.argv[1],
    "subject": {"from": sys.argv[2], "to": sys.argv[3], "interval": "[from,to)"},
    "detail": {"error": sys.argv[4], "issue_closeable_reached": None},
    "label": "collection-error",
}, ensure_ascii=False, separators=(",", ":")))
PY
)"
  printf '%s\n' "$record"
  aidd_ledger_append_record "$record" || true
  exit 1
}

# Normalize the caller's ISO-8601 values to the UTC shape emitted by GitHub.
NORMALIZED_WINDOW="$(python3 - "$FROM" "$TO" <<'PY'
import datetime, sys
def parse(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
start, end = map(parse, sys.argv[1:])
if start >= end:
    raise SystemExit("from must be earlier than to")
def utc(value):
    return value.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
print(utc(start) + "|" + utc(end))
PY
)" || exit 2
FROM="${NORMALIZED_WINDOW%%|*}"
TO="${NORMALIZED_WINDOW#*|}"
FROM_DATE="${FROM%%T*}"
TO_DATE="${TO%%T*}"
DATE_RANGE="${FROM_DATE}..${TO_DATE}"

if ! gh pr list --repo "$GITHUB_REPO" --state merged --limit "$COLLECTION_CAP" \
  --search "merged:$DATE_RANGE" \
  --json number,mergedAt,additions,deletions >"$TMP_DIR/prs.json" 2>"$TMP_DIR/prs.err"; then
  emit_error "gh pr list failed: $(tr '\n' ' ' <"$TMP_DIR/prs.err")"
fi

python3 - "$TMP_DIR/prs.json" "$FROM" "$TO" >"$TMP_DIR/in-window-prs.json" <<'PY' \
  || emit_error "cannot filter merged PRs"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
start, end = sys.argv[2:]
print(json.dumps([row for row in rows if row.get("mergedAt") and start <= row["mergedAt"] < end]))
PY

: >"$TMP_DIR/commits.jsonl"
while IFS= read -r number; do
  [[ -n "$number" ]] || continue
  if ! gh pr view "$number" --repo "$GITHUB_REPO" --json commits \
    >"$TMP_DIR/pr-$number.json" 2>"$TMP_DIR/pr-$number.err"; then
    emit_error "gh pr view $number failed: $(tr '\n' ' ' <"$TMP_DIR/pr-$number.err")"
  fi
  python3 - "$number" "$TMP_DIR/pr-$number.json" >>"$TMP_DIR/commits.jsonl" <<'PY' \
    || emit_error "cannot parse commits for PR $number"
import json, sys
number = int(sys.argv[1])
for commit in json.load(open(sys.argv[2], encoding="utf-8")).get("commits", []):
    print(json.dumps({"pr": number, "commit": commit}, separators=(",", ":")))
PY
done < <(python3 - "$TMP_DIR/in-window-prs.json" <<'PY'
import json, sys
for row in json.load(open(sys.argv[1], encoding="utf-8")):
    print(row["number"])
PY
)

if ! gh issue list --repo "$GITHUB_REPO" --state all --limit "$COLLECTION_CAP" \
  --search "created:$DATE_RANGE" \
  --json number,createdAt,closedAt >"$TMP_DIR/issues-created.json" 2>"$TMP_DIR/issues-created.err"; then
  emit_error "gh issue list (created) failed: $(tr '\n' ' ' <"$TMP_DIR/issues-created.err")"
fi
if ! gh issue list --repo "$GITHUB_REPO" --state all --limit "$COLLECTION_CAP" \
  --search "closed:$DATE_RANGE" \
  --json number,createdAt,closedAt >"$TMP_DIR/issues-closed.json" 2>"$TMP_DIR/issues-closed.err"; then
  emit_error "gh issue list (closed) failed: $(tr '\n' ' ' <"$TMP_DIR/issues-closed.err")"
fi
if ! gh run list --repo "$GITHUB_REPO" --workflow "$CD_WORKFLOW" --limit "$COLLECTION_CAP" \
  --created "$DATE_RANGE" \
  --json databaseId,createdAt,conclusion,status >"$TMP_DIR/runs.json" 2>"$TMP_DIR/runs.err"; then
  emit_error "gh run list failed: $(tr '\n' ' ' <"$TMP_DIR/runs.err")"
fi

python3 - "$COLLECTION_CAP" "$TMP_DIR/prs.json" "$TMP_DIR/issues-created.json" \
  "$TMP_DIR/issues-closed.json" "$TMP_DIR/runs.json" <<'PY' \
  || emit_error "one or more GitHub collections reached the 1000-item safety cap"
import json, sys
cap = int(sys.argv[1])
for path in sys.argv[2:]:
    if len(json.load(open(path, encoding="utf-8"))) >= cap:
        raise SystemExit(1)
PY

RECORD="$(python3 - "$TMP_DIR/in-window-prs.json" "$TMP_DIR/commits.jsonl" \
  "$TMP_DIR/issues-created.json" "$TMP_DIR/issues-closed.json" "$TMP_DIR/runs.json" \
  "$GITHUB_REPO" "$FROM" "$TO" "$CD_WORKFLOW" <<'PY'
import json
import re
import sys
from collections import Counter, defaultdict

prs_path, commits_path, created_path, closed_path, runs_path, repo, start, end, workflow = sys.argv[1:]
prs = json.load(open(prs_path, encoding="utf-8"))
created_issues = json.load(open(created_path, encoding="utf-8"))
closed_issues = json.load(open(closed_path, encoding="utf-8"))
runs = json.load(open(runs_path, encoding="utf-8"))
commit_rows = [json.loads(line) for line in open(commits_path, encoding="utf-8") if line.strip()]

tools = ("claude-code", "codex", "cursor", "opencode")
commit_by_tool = Counter({tool: 0 for tool in (*tools, "unknown")})
pr_tools = defaultdict(set)
pattern = re.compile(r"^Agent-Lane:\s*(\S+)\s*$", re.MULTILINE)
for row in commit_rows:
    commit = row["commit"]
    text = (commit.get("messageHeadline") or "") + "\n\n" + (commit.get("messageBody") or "")
    trailers = pattern.findall(text)
    tool = trailers[0] if len(trailers) == 1 and trailers[0] in tools else "unknown"
    commit_by_tool[tool] += 1
    pr_tools[row["pr"]].add(tool)

pr_by_tool = Counter({tool: 0 for tool in (*tools, "unknown")})
for pr in prs:
    observed = pr_tools.get(pr["number"], {"unknown"})
    for tool in observed:
        pr_by_tool[tool] += 1

created = sum(1 for issue in created_issues if issue.get("createdAt") and start <= issue["createdAt"] < end)
closed = sum(1 for issue in closed_issues if issue.get("closedAt") and start <= issue["closedAt"] < end)
window_runs = [run for run in runs if run.get("createdAt") and start <= run["createdAt"] < end]
successful_runs = sum(1 for run in window_runs if run.get("conclusion") == "success")

record = {
    "component": "H10",
    "event": "measure",
    "repo": repo,
    "subject": {"from": start, "to": end, "interval": "[from,to)"},
    "detail": {
        "activity": {
            "changed_lines": sum((pr.get("additions") or 0) + (pr.get("deletions") or 0) for pr in prs),
            "commits": len(commit_rows),
            "agent_lane": {
                tool: {"commits": commit_by_tool[tool], "prs": pr_by_tool[tool]}
                for tool in (*tools, "unknown")
            },
        },
        "landing": {
            "merged_prs": len(prs),
            "issues_created": created,
            "issues_closed": closed,
            "issues_open_net": created - closed,
            "cd": {
                "workflow": workflow,
                "success": successful_runs,
                "total": len(window_runs),
                "rate": (successful_runs / len(window_runs)) if window_runs else None,
            },
            "issue_closeable_reached": None,
        },
        "limits": [
            "issue-closeable transitions have no machine-readable historical source",
            "Agent-Lane attribution uses an exact single trailer only",
        ],
    },
    "label": "stage-landing-window",
}
print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
PY
)" || emit_error "cannot calculate stage landing metrics"

printf '%s\n' "$RECORD"
aidd_ledger_append_record "$RECORD"
