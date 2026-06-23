#!/bin/bash
# test-pre-merge-base-freshness.sh — PRE_MERGE must use a fresh base snapshot

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
TMP_HOME="$TMP_ROOT/home"
TMP_REPO="$TMP_ROOT/repo"
TMP_REMOTE="$TMP_ROOT/remote.git"
TMP_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_REPO/.claude/state"
ERR_FILE="$TMP_ROOT/pre-merge-base.err"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_HOME" "$TMP_BIN" "$STATE_DIR"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '# base\n' > "$TMP_REPO/README.md"
git -C "$TMP_REPO" add README.md
git -C "$TMP_REPO" commit -q -m init
git -C "$TMP_REPO" branch develop
git -C "$TMP_REPO" branch -M feature
git clone -q --bare "$TMP_REPO" "$TMP_REMOTE"
git -C "$TMP_REPO" remote add origin "$TMP_REMOTE"
git -C "$TMP_REPO" push -q origin develop
BASE_SHA="$(git -C "$TMP_REPO" rev-parse develop)"

cat > "$TMP_BIN/gh" <<'FAKEGH'
#!/bin/sh
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123" ]; then
  if [ "${3:-}" = "--jq" ]; then
    case "${4:-}" in
      ".head.ref") printf 'feature\n' ;;
      ".head.sha") printf 'abc123\n' ;;
      ".base.ref") printf 'develop\n' ;;
      ".base.sha") printf '%s\n' "${FAKE_BASE_SHA:-}" ;;
      ".state") printf 'open\n' ;;
      *) printf 'abc123\n' ;;
    esac
    exit 0
  fi
  printf '{"head":{"sha":"abc123","ref":"feature"},"base":{"ref":"develop","sha":"%s"},"state":"open"}\n' "${FAKE_BASE_SHA:-}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/999" ]; then
  if [ "${3:-}" = "--jq" ]; then
    case "${4:-}" in
      ".head.ref") printf 'other-feature\n' ;;
      ".head.sha") printf 'def999\n' ;;
      ".base.ref") printf 'develop\n' ;;
      ".base.sha") printf '%s\n' "${FAKE_BASE_SHA:-}" ;;
      ".state") printf 'open\n' ;;
      *) printf 'def999\n' ;;
    esac
    exit 0
  fi
  printf '{"head":{"sha":"def999","ref":"other-feature"},"base":{"ref":"develop","sha":"%s"},"state":"open"}\n' "${FAKE_BASE_SHA:-}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/git/ref/heads/develop" ]; then
  if [ "${3:-}" = "--jq" ] && [ "${4:-}" = ".object.sha" ]; then
    printf '%s\n' "${FAKE_BASE_SHA:-}"
    exit 0
  fi
  printf '{"object":{"sha":"%s"}}\n' "${FAKE_BASE_SHA:-}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls/123/files" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf 'README.md\n'
  else
    printf '[{"filename":"README.md"}]\n'
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/commits/abc123/check-runs" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf '0\n'
  else
    printf '{"check_runs":[]}\n'
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/commits/def999/check-runs" ]; then
  if [ "${3:-}" = "--jq" ]; then
    printf '1\n'
  else
    printf '{"check_runs":[{"name":"unit","status":"completed","conclusion":"failure"}]}\n'
  fi
  exit 0
fi
exit 1
FAKEGH
chmod +x "$TMP_BIN/gh"

write_review_status() {
  python3 - "$STATE_DIR/review-status.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as f:
    json.dump({"feature": {"code_review": True}}, f)
PY
}

run_pre_merge() {
  local base_sha="$1"
  local merge_cmd="${2:-gh pr merge 123 --merge --repo owner/repo}"
  local payload
  printf -v payload '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$merge_cmd"
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$TMP_REPO" PATH="$TMP_BIN:$PATH" FAKE_BASE_SHA="$base_sha" \
      GATE_MODE=PRE_MERGE bash "$ROOT/hooks/pr-ci-review-gate.sh" <<<"$payload"
  ) >/dev/null 2>"$ERR_FILE"
}

PASS=0
FAIL=0
TOTAL=0

expect_rc() {
  local desc="$1" expected="$2" base_sha="$3" merge_cmd="${4:-gh pr merge 123 --merge --repo owner/repo}"
  TOTAL=$((TOTAL + 1))
  write_review_status
  local rc=0
  set +e
  run_pre_merge "$base_sha" "$merge_cmd"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc (exit=$rc)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected $expected, got $rc)" >&2
    cat "$ERR_FILE" >&2 || true
  fi
}

echo "=== pre-merge base freshness ==="

expect_rc "fresh origin/develop matches GitHub base SHA" 0 "$BASE_SHA"

STALE_SHA="0000000000000000000000000000000000000000"
expect_rc "stale local base snapshot blocks merge gate" 2 "$STALE_SHA"
if grep -q "LOCAL_GATE_STALE_BASE" "$ERR_FILE"; then
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  PASS: stale base message is explicit"
else
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  FAIL: stale base message missing" >&2
  cat "$ERR_FILE" >&2 || true
fi

expect_rc "flag-before-target validates command PR, not current branch fallback" 2 "$BASE_SHA" "gh pr merge --repo owner/repo 999 --merge"
if grep -q "CI に失敗ジョブあり" "$ERR_FILE"; then
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  PASS: target PR #999 CI failure was evaluated"
else
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  FAIL: target PR #999 CI failure message missing" >&2
  cat "$ERR_FILE" >&2 || true
fi

expect_rc "chained gh pr merge commands are blocked before first-target approval" 2 "$BASE_SHA" "gh pr merge 123 --merge --repo owner/repo && gh pr merge 999 --merge --repo owner/repo"
if grep -q "複数の gh pr merge" "$ERR_FILE"; then
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  PASS: chained merge command message is explicit"
else
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  FAIL: chained merge command message missing" >&2
  cat "$ERR_FILE" >&2 || true
fi

echo "Total: $TOTAL  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
