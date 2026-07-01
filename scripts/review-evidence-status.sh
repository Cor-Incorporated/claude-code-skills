#!/usr/bin/env bash
# review-evidence-status.sh -- normalize review evidence for merge hooks.
#
# Exit codes:
#   0: requested evidence is current for the supplied head SHA
#   1: invalid usage/runtime failure
#   2: evidence is missing, stale, or SHA-less for the requested requirement
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: review-evidence-status.sh --branch BRANCH --head-sha SHA [options]

Options:
  --pr-number PR             Read pr-review-read.json for this PR
  --project-dir DIR          Project root whose .claude/state should be read
  --global-state-dir DIR     Global state dir (default: $HOME/.claude/state)
  --gstack-jsonl PATH        Optional gstack JSONL evidence file (repeatable)
  --require full|code-review|codex-review|read|none
                             Required evidence to enforce (default: full)
  --json                     Emit JSON summary
EOF
}

BRANCH=""
HEAD_SHA=""
PR_NUMBER=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
GLOBAL_STATE_DIR="${HOME}/.claude/state"
REQUIRE="full"
JSON_OUTPUT="false"
GSTACK_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --head-sha)
      HEAD_SHA="${2:-}"
      shift 2
      ;;
    --pr-number)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --global-state-dir)
      GLOBAL_STATE_DIR="${2:-}"
      shift 2
      ;;
    --gstack-jsonl)
      GSTACK_FILES+=("${2:-}")
      shift 2
      ;;
    --require)
      REQUIRE="${2:-}"
      shift 2
      ;;
    --json)
      JSON_OUTPUT="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BRANCH" || -z "$HEAD_SHA" ]]; then
  usage
  exit 1
fi

case "$REQUIRE" in
  full|code-review|codex-review|read|none) ;;
  *)
    echo "ERROR: invalid --require value: $REQUIRE" >&2
    usage
    exit 1
    ;;
esac

if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 1
fi

GSTACK_JOINED=""
if [[ "${#GSTACK_FILES[@]}" -gt 0 ]]; then
  GSTACK_JOINED="$(printf '%s\n' "${GSTACK_FILES[@]}")"
fi

_BRANCH="$BRANCH" \
_HEAD_SHA="$HEAD_SHA" \
_PR_NUMBER="$PR_NUMBER" \
_PROJECT_DIR="$PROJECT_DIR" \
_GLOBAL_STATE_DIR="$GLOBAL_STATE_DIR" \
_REQUIRE="$REQUIRE" \
_JSON_OUTPUT="$JSON_OUTPUT" \
_GSTACK_FILES="$GSTACK_JOINED" \
python3 - <<'PY'
import json
import os
import re
import sys
from pathlib import Path

branch = os.environ["_BRANCH"]
head_sha = os.environ["_HEAD_SHA"].strip()
pr_number = os.environ.get("_PR_NUMBER", "").strip()
project_dir = os.environ.get("_PROJECT_DIR", "").strip()
global_state_dir = os.environ.get("_GLOBAL_STATE_DIR", "").strip()
require = os.environ["_REQUIRE"]
json_output = os.environ["_JSON_OUTPUT"] == "true"
gstack_files = [
    line for line in os.environ.get("_GSTACK_FILES", "").splitlines() if line
]


def dedupe(paths):
    seen = set()
    out = []
    for path in paths:
        if not path:
            continue
        normalized = str(Path(path).expanduser())
        if normalized in seen:
            continue
        seen.add(normalized)
        out.append(normalized)
    return out


state_dirs = []
if project_dir:
    state_dirs.append(str(Path(project_dir) / ".claude" / "state"))
if global_state_dir:
    state_dirs.append(global_state_dir)
state_dirs = dedupe(state_dirs)


def load_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception:
        return {}


def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "ok", "pass", "passed", "lgtm"}
    return False


def normalize_sha(value):
    if not isinstance(value, str):
        return ""
    return value.strip().lower()


def sha_matches(candidate, allow_prefix=False):
    candidate = normalize_sha(candidate)
    current = normalize_sha(head_sha)
    if not candidate:
        return False
    if candidate == current:
        return True
    if not allow_prefix:
        return False
    shorter, longer = sorted((candidate, current), key=len)
    return len(shorter) >= 6 and longer.startswith(shorter)


def sha_status(candidate, allow_prefix=False):
    if not normalize_sha(candidate):
        return "missing_sha"
    if sha_matches(candidate, allow_prefix):
        return "current"
    return "stale"


def diagnostic_only(status):
    return status != "current"


records = []


def add_record(kind, source, path, status, sha="", detail="", key=""):
    records.append(
        {
            "kind": kind,
            "source": source,
            "file": path,
            "key": key,
            "sha": sha or "",
            "status": status,
            "diagnostic_only": diagnostic_only(status),
            "detail": detail,
        }
    )


review_files = dedupe([str(Path(d) / "review-status.json") for d in state_dirs])
for path in review_files:
    data = load_json(path)
    entry = data.get(branch, {})
    if not isinstance(entry, dict):
        continue
    for kind, sha_key in (
        ("code_review", "code_review_sha"),
        ("codex_review", "codex_review_sha"),
    ):
        if truthy(entry.get(kind)):
            sha = str(entry.get(sha_key, "") or "")
            add_record(
                kind,
                "review-status",
                path,
                sha_status(sha),
                sha,
                f"{kind}=true",
                branch,
            )

read_files = dedupe([str(Path(d) / "pr-review-read.json") for d in state_dirs])
if pr_number:
    for path in read_files:
        data = load_json(path)
        entry = data.get(pr_number, {})
        if not isinstance(entry, dict):
            continue
        if truthy(entry.get("review_read")):
            sha = str(
                entry.get("head_sha")
                or entry.get("review_head_sha")
                or entry.get("sha")
                or ""
            )
            add_record(
                "review_read",
                "pr-review-read",
                path,
                sha_status(sha),
                sha,
                "review_read=true",
                pr_number,
            )


sha_key_pattern = re.compile(r"(?:^|[._-])(?:head_?sha|commit_?sha|commit|sha|revision|rev)$", re.I)
hex_sha_pattern = re.compile(r"\b[0-9a-fA-F]{6,40}\b")
sha_context_pattern = re.compile(
    r"\b(?:head(?:_sha)?|commit(?:_sha)?|sha|revision|rev)\b[^0-9a-fA-F]{0,16}([0-9a-fA-F]{6,40})",
    re.I,
)


def flatten_values(value, prefix=""):
    if isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            yield from flatten_values(child, child_prefix)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            yield from flatten_values(child, f"{prefix}[{index}]")
        return
    yield prefix, value


def extract_entry_sha(entry):
    for key, value in flatten_values(entry):
        if isinstance(value, str):
            match = hex_sha_pattern.search(value)
            if sha_key_pattern.search(key) and match:
                return match.group(0)
    for _, value in flatten_values(entry):
        if isinstance(value, str):
            match = sha_context_pattern.search(value)
            if match:
                return match.group(1)
    return ""


def gstack_kinds(entry):
    flattened = list(flatten_values(entry))
    text = " ".join(
        [str(key) for key, _ in flattened]
        + [str(value) for _, value in flattened if isinstance(value, (str, int, float, bool))]
    ).lower()
    kinds = []
    if (
        truthy(entry.get("code_review"))
        or "code-reviewer" in text
        or "code_review" in text
        or "code review" in text
        or ("eng" in text and "review" in text)
    ):
        kinds.append("code_review")
    return kinds


for path in gstack_files:
    try:
        with open(path) as f:
            lines = list(enumerate(f, start=1))
    except FileNotFoundError:
        add_record("gstack", "gstack-jsonl", path, "missing_file", "", "file not found")
        continue
    for line_number, line in lines:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except Exception:
            add_record("gstack", "gstack-jsonl", path, "invalid_json", "", f"line {line_number}")
            continue
        if not isinstance(entry, dict):
            add_record("gstack", "gstack-jsonl", path, "invalid_json", "", f"line {line_number}")
            continue
        sha = extract_entry_sha(entry)
        kinds = gstack_kinds(entry)
        if not kinds:
            if sha:
                add_record("gstack", "gstack-jsonl", path, sha_status(sha, allow_prefix=True), sha, f"line {line_number}")
            continue
        for kind in kinds:
            add_record(kind, "gstack-jsonl", path, sha_status(sha, allow_prefix=True), sha, f"line {line_number}")


required_map = {
    "full": ["code_review", "codex_review"],
    "code-review": ["code_review"],
    "codex-review": ["codex_review"],
    "read": ["review_read"],
    "none": [],
}
required = required_map[require]
current_by_kind = {
    kind: any(record["kind"] == kind and record["status"] == "current" for record in records)
    for kind in set(required + ["code_review", "codex_review", "review_read"])
}
missing = [kind for kind in required if not current_by_kind.get(kind, False)]
ok = not missing

summary = {
    "ok": ok,
    "require": require,
    "branch": branch,
    "head_sha": head_sha,
    "missing": missing,
    "current": sorted([kind for kind, value in current_by_kind.items() if value]),
    "records": records,
}

if json_output:
    print(json.dumps(summary, indent=2, sort_keys=True))
else:
    print(f"review-evidence require={require} branch={branch} head_sha={head_sha} ok={str(ok).lower()}")
    for kind in ("code_review", "codex_review", "review_read"):
        status = "current" if current_by_kind.get(kind, False) else "missing"
        print(f"{kind}: {status}")
    for record in records:
        if record["status"] != "current":
            print(
                "diagnostic: "
                f"{record['kind']} {record['status']} "
                f"source={record['source']} file={record['file']} sha={record['sha']}"
            )

raise SystemExit(0 if ok else 2)
PY
