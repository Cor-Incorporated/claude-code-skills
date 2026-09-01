#!/bin/bash
# test-issue-183.sh — Issue #183: Hook deployment integrity enforcement
# Tests enforce-hook-deploy-integrity.sh, enforce-hook-deploy-after-merge.sh
# (gate-modes/stop.sh coverage removed by ADR-006 — gate-modes retired entirely)
set -uo pipefail


export AIDD_LEDGER_SOURCE=test  # T9-2: ledger rows from test harness are source=test
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
FAKE_CODEX_HOOKS="${TMPDIR_BASE}/installed/codex-hooks"
FAKE_CURSOR_HOOKS="${TMPDIR_BASE}/installed/cursor-hooks"
FAKE_SETTINGS="${TMPDIR_BASE}/settings.json"
mkdir -p "$FAKE_PROJECT_HOOKS" "$FAKE_INSTALLED_HOOKS" \
  "$FAKE_CODEX_HOOKS" "$FAKE_CURSOR_HOOKS"

# The hook only treats a directory as a Claude Code hooks dir when it carries the
# git-push-guard.sh sentinel (2026-09-01: a bare -d test matched aidd-governance's
# unrelated *git* hooks dir and reported all 20 deployed hooks as orphans).
# The fixture must therefore look like a real hooks dir, not just be named one.
# Deployed on both sides so it never itself shows up as a diff in these tests.
printf '#!/bin/bash\n# sentinel\n' > "${FAKE_PROJECT_HOOKS}/git-push-guard.sh"
cp "${FAKE_PROJECT_HOOKS}/git-push-guard.sh" "${FAKE_INSTALLED_HOOKS}/git-push-guard.sh"

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
  -e "s|CODEX_HOOKS_DIR=.*|CODEX_HOOKS_DIR=\"${FAKE_CODEX_HOOKS}\"|" \
  -e "s|CURSOR_HOOKS_DIR=.*|CURSOR_HOOKS_DIR=\"${FAKE_CURSOR_HOOKS}\"|" \
  -e "s|SETTINGS_FILE=.*|SETTINGS_FILE=\"${FAKE_SETTINGS}\"|" \
  "$H1" > "$PATCHED_H1"
chmod +x "$PATCHED_H1"

# --- T1: Detects when a hook file is missing from deploy dir ---
echo '#!/bin/bash' > "${FAKE_PROJECT_HOOKS}/test-missing.sh"
chmod +x "${FAKE_PROJECT_HOOKS}/test-missing.sh"

CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" >/dev/null 2>&1
check_exit 0 $? "T1: always exits 0 (missing hook scenario)"

# --- T2: Does NOT auto-sync missing hook (loop-break T2: detect-only) ---
STDERR_T2=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
if [ ! -f "${FAKE_INSTALLED_HOOKS}/test-missing.sh" ] \
   && echo "$STDERR_T2" | grep -q "NOT INSTALLED.*test-missing.sh"; then
  PASS=$((PASS+1)); echo "--- T2: Missing hook reported, not auto-copied ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T2: Missing hook reported, not auto-copied ---"
  echo "  FAIL (exists=$( [ -f "${FAKE_INSTALLED_HOOKS}/test-missing.sh" ] && echo yes || echo no ); stderr has NOT INSTALLED=$(echo "$STDERR_T2" | grep -c NOT))"
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

# --- T5: Does NOT auto-sync MD5 mismatch (deploy stays different) ---
REPO_MD5=$(md5 -q "${FAKE_PROJECT_HOOKS}/test-mismatch.sh" 2>/dev/null || md5sum "${FAKE_PROJECT_HOOKS}/test-mismatch.sh" | awk '{print $1}')
DEPLOY_MD5=$(md5 -q "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh" 2>/dev/null || md5sum "${FAKE_INSTALLED_HOOKS}/test-mismatch.sh" | awk '{print $1}')
if [ "$REPO_MD5" != "$DEPLOY_MD5" ]; then
  PASS=$((PASS+1)); echo "--- T5: MD5 mismatch left uncorrected (no auto-sync) ---"
  echo "  PASS (repo=$REPO_MD5 deploy=$DEPLOY_MD5)"
else
  FAIL=$((FAIL+1)); echo "--- T5: MD5 mismatch left uncorrected (no auto-sync) ---"
  echo "  FAIL (unexpected equal repo=$REPO_MD5 deploy=$DEPLOY_MD5)"
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

# --- T8: Matching Codex/Cursor hooks use their own deploy roots ---
mkdir -p "${FAKE_PROJECT_HOOKS}/codex" "${FAKE_PROJECT_HOOKS}/cursor"
printf '#!/bin/bash\necho codex\n' > "${FAKE_PROJECT_HOOKS}/codex/test-codex-match.sh"
cp "${FAKE_PROJECT_HOOKS}/codex/test-codex-match.sh" "${FAKE_CODEX_HOOKS}/test-codex-match.sh"
printf '#!/bin/bash\necho cursor\n' > "${FAKE_PROJECT_HOOKS}/cursor/test-cursor-match.sh"
cp "${FAKE_PROJECT_HOOKS}/cursor/test-cursor-match.sh" "${FAKE_CURSOR_HOOKS}/test-cursor-match.sh"

STDERR_CROSS_TOOL=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
if ! echo "$STDERR_CROSS_TOOL" | grep -qE "(NOT INSTALLED|MD5 MISMATCH): (codex/test-codex-match|cursor/test-cursor-match)"; then
  PASS=$((PASS+1)); echo "--- T8: Matching cross-tool hooks resolve to tool-specific roots ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T8: Matching cross-tool hooks resolve to tool-specific roots ---"
  echo "  FAIL (cross-tool hook was checked against the wrong deploy root)"
fi

# --- T9: Codex mismatch still reports both hashes and the correct target ---
printf '# deployed drift\n' >> "${FAKE_CODEX_HOOKS}/test-codex-match.sh"
STDERR_CODEX_MISMATCH=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
if echo "$STDERR_CODEX_MISMATCH" | grep -q "MD5 MISMATCH: codex/test-codex-match.sh (repo=.*deployed=.*target=${FAKE_CODEX_HOOKS}/test-codex-match.sh"; then
  PASS=$((PASS+1)); echo "--- T9: Codex mismatch reports repo/deployed values and target ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T9: Codex mismatch reports repo/deployed values and target ---"
  echo "  FAIL (mismatch evidence or target missing)"
fi

# --- T10: Cursor missing deployment reports the Cursor target ---
rm "${FAKE_CURSOR_HOOKS}/test-cursor-match.sh"
STDERR_CURSOR_MISSING=$(CLAUDE_PROJECT_DIR="${TMPDIR_BASE}/project" bash "$PATCHED_H1" 2>&1 >/dev/null)
if echo "$STDERR_CURSOR_MISSING" | grep -q "NOT INSTALLED: cursor/test-cursor-match.sh (target=${FAKE_CURSOR_HOOKS}/test-cursor-match.sh"; then
  PASS=$((PASS+1)); echo "--- T10: Cursor missing deployment reports Cursor target ---"
  echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "--- T10: Cursor missing deployment reports Cursor target ---"
  echo "  FAIL (wrong or missing Cursor target)"
fi

# --- T10b/T10c: sentinel guard — a dir merely NAMED hooks/ must not be adopted ---
# Regression for 2026-09-01: aidd-governance ships hooks/pre-commit for
# `git config core.hooksPath`. The old bare `-d` test adopted that *git* hooks
# dir, so all 20 correctly deployed hooks failed the Phase 3 orphan check and the
# hook printed "UNKNOWN ORPHAN" x20 plus the remedy "checkout develop && bash
# setup.sh" — which re-enacts the 2026-07-22 hook-loss incident.
# Fully sandboxed via HOME (pattern from test-h1-no-progress.sh) so neither the
# real ~/.claude/hooks nor the $HOME/Developer/claude-code-skills fallback
# participates; the only candidate is the decoy.
# Falsifiable: drop `-f "$candidate/$HOOKS_DIR_SENTINEL"` from the hook and the
# decoy gets adopted, turning all 3 sandbox-deployed hooks into orphans.
SB_SENTINEL="${TMPDIR_BASE}/sentinel-home"
mkdir -p "${SB_SENTINEL}/.claude/hooks" "${SB_SENTINEL}/gitproj/hooks"
for h in alpha bravo charlie; do
  printf '#!/bin/bash\n# deployed\n' > "${SB_SENTINEL}/.claude/hooks/${h}.sh"
done
printf '#!/bin/bash\n# a git hook, not a Claude Code hook\n' > "${SB_SENTINEL}/gitproj/hooks/pre-commit"

STDERR_SENTINEL=$(env HOME="$SB_SENTINEL" CLAUDE_PROJECT_DIR="${SB_SENTINEL}/gitproj" \
  bash "${HOOK_DIR}/enforce-hook-deploy-integrity.sh" 2>&1 >/dev/null)
ORPHANS=$(printf '%s' "$STDERR_SENTINEL" | grep -c 'UNKNOWN ORPHAN' || true)

echo "--- T10b: git-hooks decoy rejected by sentinel (no orphan storm) ---"
if [ "$ORPHANS" -eq 0 ] && printf '%s' "$STDERR_SENTINEL" | grep -q 'SKIPPED'; then
  PASS=$((PASS+1)); echo "  PASS"
else
  FAIL=$((FAIL+1))
  echo "  FAIL (orphans=${ORPHANS}, expected 0 plus a SKIPPED notice)"
  echo "  stderr: ${STDERR_SENTINEL}"
fi

# A silent skip is indistinguishable from a clean run — the one conclusion this
# hook must never imply when the comparison did not happen.
echo "--- T10c: skip is announced on stderr, not silent ---"
if [ -n "$STDERR_SENTINEL" ]; then
  PASS=$((PASS+1)); echo "  PASS"
else
  FAIL=$((FAIL+1)); echo "  FAIL (stderr empty)"
fi

echo ""
echo "==================================="
echo "Hook 2: enforce-hook-deploy-after-merge.sh"
echo "==================================="
echo ""

H2="${HOOK_DIR}/enforce-hook-deploy-after-merge.sh"

# --- T11: Early exit for non-merge commands ---
mk_json 'ls -la' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T11: non-merge command (ls -la) -> exit 0"

# --- T12: Early exit for non-gh commands ---
mk_json 'echo "hello world"' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T12: non-gh command (echo) -> exit 0"

# --- T13: Early exit for gh command without merge ---
mk_json 'gh pr list' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T13: gh pr list (not merge) -> exit 0"

# --- T14: Early exit when PR number cannot be extracted ---
mk_json 'gh pr merge' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T14: gh pr merge without PR number -> exit 0"

# --- T15: Early exit for git commands (not gh) ---
mk_json 'git merge main' | bash "$H2" >/dev/null 2>&1
check_exit 0 $? "T15: git merge (not gh pr merge) -> exit 0"

echo ""
echo "===================================="
echo "RESULTS: ${PASS} passed, ${FAIL} failed (total $((PASS+FAIL)))"
echo "===================================="
exit $FAIL
