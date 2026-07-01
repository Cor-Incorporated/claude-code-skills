#!/usr/bin/env bash
# test-post-merge-close-issues.sh — post-merge close hook only closes explicit closing refs
set -euo pipefail

PASS=0
FAIL=0
TOTAL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/post-merge-close-issues.sh"
TMP_DIR=""
LAST_OUTPUT=""
LAST_RC=0

cleanup() {
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "${GREEN}  PASS${NC} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "${RED}  FAIL${NC} $1"
}

TMP_DIR=$(mktemp -d)
LOG_FILE="$TMP_DIR/gh.log"
BODY_FILE="$TMP_DIR/pr-body.md"

cat > "$TMP_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo "Cor-Incorporated/claude-code-skills"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case " $* " in
    *" --json state "*) echo "MERGED" ;;
    *" --json body "*) cat "$GH_BODY_FILE" ;;
    *) echo "{}" ;;
  esac
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "view" ]]; then
  echo "OPEN"
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "closed"
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/gh"

run_hook() {
  local body="$1"
  printf '%s\n' "$body" > "$BODY_FILE"
  : > "$LOG_FILE"
  LAST_OUTPUT=""
  LAST_RC=0
  set +e
  LAST_OUTPUT=$(
    PATH="$TMP_DIR:$PATH" GH_LOG="$LOG_FILE" GH_BODY_FILE="$BODY_FILE" bash "$HOOK" 2>&1 <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --squash"}}
JSON
  )
  LAST_RC=$?
  set -e
}

expect_no_close() {
  local label="$1"
  local body="$2"
  run_hook "$body"
  if [[ "$LAST_RC" -eq 0 ]] && ! grep -q 'issue close' "$LOG_FILE"; then
    pass "$label"
  else
    fail "$label (exit $LAST_RC: $LAST_OUTPUT; log: $(cat "$LOG_FILE"))"
  fi
}

expect_close() {
  local label="$1"
  local body="$2"
  run_hook "$body"
  if [[ "$LAST_RC" -eq 0 ]] && grep -q 'issue close 220' "$LOG_FILE"; then
    pass "$label"
  else
    fail "$label (exit $LAST_RC: $LAST_OUTPUT; log: $(cat "$LOG_FILE"))"
  fi
}

echo "=== post-merge close Issue tests ==="

expect_no_close \
  "T1: Refs-only PR does not call gh issue close" \
  $'## Summary\nRefs #220\n'

expect_no_close \
  "T2: Issue URL-only PR does not call gh issue close" \
  $'## Summary\nhttps://github.com/Cor-Incorporated/Grift/issues/1261\n'

expect_close \
  "T3: closing keyword PR still closes the Issue" \
  $'## Summary\nCloses #220\n'

echo ""
echo "Results: $PASS passed, $FAIL failed (total $TOTAL)"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
