#!/bin/bash
# test-issue-183.sh — Issue #183: Hook deployment integrity enforcement
# Tests enforce-hook-deploy-integrity.sh, enforce-hook-deploy-after-merge.sh, gate-modes/stop.sh
set -uo pipefail

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="${SCRIPT_DIR}/../hooks"

check_exit() {
  local expected=$1 actual=$2 label="$3"
  echo "--- $label ---"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS+1)); echo "  PASS"
  else
    FAIL=$((FAIL+1)); echo "  FAIL (expected $expected, got $actual)"
  fi
}

mk_json() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

# ===================================================================
# Setup: Create temp directories to avoid affecting real deployments
# ===================================================================
TMPDIR_BASE=$(mktemp -d)
FAKE_PROJECT_HOOKS="${TMPDIR_BASE}/project/hooks"
FAKE_INSTALLED_HOOKS="${TMPDIR_BASE}/installed/hooks"
FAKE_SETTINGS="${TMPDIR_BASE}/settings.json"
mkdir -p "$FAKE_PROJECT_HOOKS" "$FAKE_INSTALLED_HOOKS"

# Create a minimal settings.json that references our test hooks
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"bash ~/.claude/hooks/test-missing.sh"}]}]}}' > "$FAKE_SETTINGS"

cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

echo "==================================="
echo "Hook 1: enforce-hook-deploy-integrity.sh"
echo "==================================="
echo ""

H1="${HOOK_DIR}/enforce-hook-deploy-integrity.sh"

# Create a patched version that uses our temp dirs
PATCHED_H1="${TMPDIR_BASE}/patched-integrity.sh"
sed \
  -e "s|INSTALLED_HOOKS_DIR=.*|INSTALLED_HOOKS_DIR=\"${FAKE_INSTALLED_HOOKS}\"|" \
  -e "s|SETTINGS_FILE=.*|SETTINGS_FILE=\"${FAKE_SETTINGS}\"|" \
  "$H1" > "$PATCHED_H1"
chmod +x "$PATCHED_H1"

# --- T1: Detects when a hook file is missing from deploy dir ---
echo '#!/bin/bash' > "${FAKE_PROJECT_HOOKS}/test-missing.sh"
chmod +x "${FAKE_PROJECT_HOOKS}/test-missing.sh"

CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" >/dev/null 2>&1
check_exit 0 $? "T1: always exits 0 (missing hook scenario)"

# --- T2: Auto-synced missing hook to deploy dir ---
if [ -f "${FAKE_INSTALLED_HOOKS}/test-missing.sh" ]; then
  PASS=$((PASS+1)); echo "--- T2: Auto-synced missing hook to deploy dir ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T2: Auto-synced missing hook to deploy dir ---"
  echo "  FAIL (file not copied)"
fi

# --- T3: Detects MD5 mismatch ---
echo '#!/bin/bash' > "${FAKE_PROJECT_HOOKS}/test-mismatch.sh"
echo '#!/bin/bash' > "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh"
echo '# different content in deployed version' >> "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh"

STDERR_OUT=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
EXIT_CODE=$?
check_exit 0 $EXIT_CODE "T3: always exits 0 (MD5 mismatch scenario)"

if echo "$STDERR_OUT" | grep -q "MD5 MISMATCH.*test-mismatch.sh"; then
  PASS=$((PASS+1)); echo "--- T4: MD5 mismatch detected in stderr ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T4: MD5 mismatch detected in stderr ---"
  echo "  FAIL (mismatch not reported)"
fi

# --- T5: Auto-syncs mismatched files (MD5 now matches after sync) ---
REPO_MD5=$(md5 -q "${FAKE_PROJECT_HOOKS}/test-mismatch.sh" 2>/dev/null || md5sum "${FAKE_PROJECT_HOOKS}/test-mismatch.sh" | awk '{print $1}')
DEPLOY_MD5=$(md5 -q "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh" 2>/dev/null || md5sum "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh" | awk '{print $1}')
if [ "$REPO_MD5" = "$DEPLOY_MD5" ]; then
  PASS=$((PASS+1)); echo "--- T5: Auto-synced mismatched hook (MD5 now matches) ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T5: Auto-synced mismatched hook (MD5 now matches) ---"
  echo "  FAIL (repo=$REPO_MD5 deploy=$DEPLOY_MD5)"
fi

# --- T6: Detects orphan hooks ---
echo '#!/bin/bash' > "${FAKE_INSTALLED_HOOKS}/orphan-hook.sh"
chmod +x "${FAKE_INSTALLED_HOOKS}/orphan-hook.sh"

STDERR_OUT=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
EXIT_CODE=$?
check_exit 0 $EXIT_CODE "T6: always exits 0 (orphan detection scenario)"

if echo "$STDERR_OUT" | grep -q "ORPHAN.*orphan-hook.sh"; then
  PASS=$((PASS+1)); echo "--- T7: Orphan hook detected in stderr ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T7: Orphan hook detected in stderr ---"
  echo "  FAIL (orphan not reported)"
fi

echo ""
echo "==================================="
echo "Hook 2: enforce-hook-deploy-after-merge.sh"
echo "==================================="
echo ""

H2="${HOOK_DIR}/enforce-hook-deploy-after-merge.sh"

# --- T8: Early exit for non-merge commands ---
mk_json 'ls -la' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T8: non-merge command (ls -la) -> exit 0"

# --- T9: Early exit for non-gh commands ---
mk_json 'echo "hello world"' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T9: non-gh command (echo) -> exit 0"

# --- T10: Early exit for gh command without merge ---
mk_json 'gh pr list' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T10: gh pr list (not merge) -> exit 0"

# --- T11: Early exit when PR number cannot be extracted ---
mk_json 'gh pr merge' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T11: gh pr merge without PR number -> exit 0"

# --- T12: Early exit for git commands (not gh) ---
mk_json 'git merge main' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T12: git merge (not gh pr merge) -> exit 0"

echo ""
echo "==================================="
echo "Hook 3: gate-modes/stop.sh (#181 fix)"
echo "==================================="
echo ""

H3="${HOOK_DIR}/gate-modes/stop.sh"

# --- Setup: Create temp state for stop.sh ---
FAKE_STATE_DIR="${TMPDIR_BASE}/state"
mkdir -p "$FAKE_STATE_DIR"
FAKE_LOCK_STATE="${FAKE_STATE_DIR}/pr-review-lock.json"

# Create a patched stop.sh that uses our fake state file
PATCHED_STOP="${TMPDIR_BASE}/patched-stop.sh"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo "GATE_MODES_DIR=\"${HOOK_DIR}/gate-modes\""
  echo "source \"\${GATE_MODES_DIR}/common.sh\""
  echo "LOCK_STATE=\"${FAKE_LOCK_STATE}\""
  # Append the rest of stop.sh starting after the source line (line 18+)
  tail -n +18 "$H3"
} > "$PATCHED_STOP"
chmod +x "$PATCHED_STOP"

# --- T13: STOP mode exits 0 with pending CI ---
cat > "$FAKE_LOCK_STATE" <<'JSONEOF'
{
  "999": {
    "branch": "test-branch",
    "ci_green": false,
    "verified": false
  }
}
JSONEOF

bash "$PATCHED_STOP" </dev/null >/dev/null 2>&1
check_exit 0 $? "T13: STOP mode exits 0 with CI pending"

# --- T14: STOP mode exits 0 with unverified PR ---
cat > "$FAKE_LOCK_STATE" <<'JSONEOF'
{
  "888": {
    "branch": "failed-branch",
    "ci_green": true,
    "verified": false
  }
}
JSONEOF

bash "$PATCHED_STOP" </dev/null >/dev/null 2>&1
check_exit 0 $? "T14: STOP mode exits 0 with unverified PR"

# --- T15: STOP mode exits 0 with empty state ---
echo '{}' > "$FAKE_LOCK_STATE"
bash "$PATCHED_STOP" </dev/null >/dev/null 2>&1
check_exit 0 $? "T15: STOP mode exits 0 with empty state"

# --- T16: STOP mode exits 0 with mixed states ---
cat > "$FAKE_LOCK_STATE" <<'JSONEOF'
{
  "111": {"branch": "feat-a", "ci_green": false, "verified": false},
  "222": {"branch": "feat-b", "ci_green": true, "verified": false},
  "333": {"branch": "feat-c", "ci_green": true, "verified": true}
}
JSONEOF

bash "$PATCHED_STOP" </dev/null >/dev/null 2>&1
check_exit 0 $? "T16: STOP mode exits 0 with mixed pending+unverified+verified"

echo ""
echo "===================================="
echo "RESULTS: ${PASS} passed, ${FAIL} failed (total $((PASS+FAIL)))"
echo "===================================="
exit $FAIL
