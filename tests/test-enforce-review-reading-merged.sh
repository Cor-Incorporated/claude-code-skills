#!/bin/bash
# test-enforce-review-reading-merged.sh
# Verifies enforce-review-reading.sh:
#   (1) suppresses the banner AND purges pending-review-comments.json for a
#       merged/closed PR (the residue-banner bug),
#   (2) preserves the banner + hard merge-block for an OPEN PR,
#   (3) fails OPEN (still warns) when PR state cannot be determined,
#   (4) honours the TTL cache so `gh` is not consulted on every command.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/enforce-review-reading.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
TARGET_WORK="$(mktemp -d)"
GHBIN="$(mktemp -d)"
trap 'rm -rf "$WORK" "$TARGET_WORK" "$GHBIN"' EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@t.t
git -C "$WORK" config user.name t
git -C "$TARGET_WORK" init -q
git -C "$TARGET_WORK" config user.email t@t.t
git -C "$TARGET_WORK" config user.name t
STATE_DIR="$WORK/.claude/state"
TARGET_STATE_DIR="$TARGET_WORK/.claude/state"
mkdir -p "$STATE_DIR"
mkdir -p "$TARGET_STATE_DIR"
PENDING="$STATE_DIR/pending-review-comments.json"
TARGET_PENDING="$TARGET_STATE_DIR/pending-review-comments.json"
CACHE="$STATE_DIR/pending-review-pr-state.cache"
TARGET_CACHE="$TARGET_STATE_DIR/pending-review-pr-state.cache"

# gh mock: prints the configured state for any args; "FAIL" -> exit 1.
make_gh() {
  printf '#!/bin/bash\nif [ "%s" = "FAIL" ]; then exit 1; fi\necho "%s"\n' "$1" "$1" > "$GHBIN/gh"
  chmod +x "$GHBIN/gh"
}

make_gh_with_current_pr() {
  local state="$1"
  local current_pr="$2"
  cat > "$GHBIN/gh" <<FAKEGH
#!/bin/bash
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "list" ]; then
  printf '%s\n' "$current_pr"
  exit 0
fi
if [ "$state" = "FAIL" ]; then
  exit 1
fi
printf '%s\n' "$state"
FAKEGH
  chmod +x "$GHBIN/gh"
}

write_pending() {
  cat > "$PENDING" <<'JSON'
{"pr":"999","repo":"owner/repo","head_sha":"abc123","total":2,"critical":1,"high":1,"classification_method":"regex","output":"[review] PR #999 Severity: CRITICAL=1 HIGH=1"}
JSON
  rm -f "$CACHE"
}

write_target_pending() {
  cat > "$TARGET_PENDING" <<'JSON'
{"pr":"999","repo":"owner/repo","head_sha":"abc123","total":2,"critical":1,"high":1,"classification_method":"regex","output":"[review] PR #999 Severity: CRITICAL=1 HIGH=1"}
JSON
  rm -f "$TARGET_CACHE"
}

seed_cache() {  # $1 = state, $2 = age_seconds_ago
  _S="$1" _AGE="$2" _C="$CACHE" python3 -c '
import json, os, time
json.dump({"pr":"999","head_sha":"abc123","state":os.environ["_S"],
           "checked_at": time.time()-float(os.environ["_AGE"])},
          open(os.environ["_C"],"w"))
'
}

run_hook() {  # $1 = command; stdout returned, stderr -> $WORK/err
  local payload
  payload=$(jq -cn --arg command "$1" '{tool_input:{command:$command}}')
  ( cd "$WORK" && printf '%s\n' "$payload" \
      | env CLAUDE_AGENT_DEPTH=0 CLAUDE_AGENT_ID= PATH="$GHBIN:$PATH" bash "$HOOK" ) 2>"$WORK/err"
}

echo "[1] merged/closed PR -> suppress + purge"
make_gh closed; write_pending
out="$(run_hook "git status")"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc (want 0)"
printf '%s' "$out" | grep -q additionalContext && bad "banner leaked" || ok "no banner"
[ ! -f "$PENDING" ] && ok "pending purged" || bad "pending still present"

echo "[2] merged PR + 'gh pr merge' -> not hard-blocked (exit 0)"
make_gh closed; write_pending
run_hook "gh pr merge 999" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "merge not blocked on merged PR" || bad "exit $rc (want 0)"

echo "[3] OPEN PR -> banner preserved"
make_gh open; write_pending
out="$(run_hook "git status")"; rc=$?
printf '%s' "$out" | grep -q additionalContext && ok "banner shown" || bad "banner missing"
[ -f "$PENDING" ] && ok "pending kept" || bad "pending wrongly deleted"

echo "[4] OPEN PR + 'gh pr merge' -> hard-blocked (exit 2)"
make_gh open; write_pending
run_hook "gh pr merge 999" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "merge hard-blocked" || bad "exit $rc (want 2)"

echo "[5] OPEN other PR + 'gh pr merge' -> not hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge 123" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "other PR merge not hard-blocked" || bad "exit $rc (want 0)"
[ -f "$PENDING" ] && ok "other PR pending kept" || bad "other PR pending wrongly deleted"

echo "[5b] OPEN other PR URL target -> hard-blocked as unsafe"
make_gh open; write_pending
run_hook "gh pr merge https://github.com/owner/repo/pull/123 --merge" >/dev/null; rc=$?
if [ "$rc" -eq 2 ] && grep -q "target: https://github.com/owner/repo/pull/123" "$WORK/err"; then
  ok "PR URL target hard-blocked"
else
  bad "exit $rc or missing unsafe target message (want exit 2)"
fi

echo "[5c] OPEN other PR URL target through bash -c -> hard-blocked as unsafe"
make_gh open; write_pending
run_hook "bash -c 'gh pr merge https://github.com/owner/repo/pull/123 --merge'" >/dev/null; rc=$?
if [ "$rc" -eq 2 ] && grep -q "target: https://github.com/owner/repo/pull/123" "$WORK/err"; then
  ok "wrapped PR URL target hard-blocked"
else
  bad "exit $rc or missing wrapped unsafe target message (want exit 2)"
fi

echo "[6] OPEN other PR + flag-before-target 'gh pr merge' -> not hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge --repo owner/repo 123 --merge" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "flag-before-target other PR not hard-blocked" || bad "exit $rc (want 0)"

echo "[7] OPEN same PR + flag-before-target 'gh pr merge' -> hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge --repo owner/repo 999 --merge" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "flag-before-target same PR hard-blocked" || bad "exit $rc (want 2)"

echo "[8] OPEN other PR + short author-email before target -> not hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge -A reviewer@example.com 123 --merge --repo owner/repo" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "author-email other PR not hard-blocked" || bad "exit $rc (want 0)"

echo "[8b] OPEN same PR + global -R before pr -> hard-blocked"
make_gh open; write_pending
run_hook "gh -R owner/repo pr merge 999 --merge" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "global -R same PR hard-blocked" || bad "exit $rc (want 2)"

echo "[9] OPEN other current-branch PR + implicit 'gh pr merge' -> not hard-blocked"
make_gh_with_current_pr open 123; write_pending
run_hook "gh pr merge --merge --repo owner/repo" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "implicit other PR not hard-blocked" || bad "exit $rc (want 0)"

echo "[10] OPEN chained 'gh pr merge' -> hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge 123 --merge --repo owner/repo && gh pr merge 999 --merge --repo owner/repo" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "chained merge hard-blocked" || bad "exit $rc (want 2)"

echo "[11] OPEN unresolved implicit 'gh pr merge' -> hard-blocked with explicit PR requirement"
make_gh_with_current_pr open ""; write_pending
run_hook "gh pr merge --merge --repo owner/repo" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "unresolved implicit merge hard-blocked" || bad "exit $rc (want 2)"

echo "[12] OPEN same PR after first line -> hard-blocked"
make_gh open; write_pending
run_hook $'true\ngh pr merge 999 --merge --repo owner/repo' >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "multiline same PR hard-blocked" || bad "exit $rc (want 2)"

echo "[13] OPEN chained multiline 'gh pr merge' -> hard-blocked"
make_gh open; write_pending
run_hook $'gh pr merge 123 --merge --repo owner/repo\ngh pr merge 999 --merge --repo owner/repo' >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "multiline chained merge hard-blocked" || bad "exit $rc (want 2)"

echo "[13b] OPEN heredoc body mentioning 'gh pr merge' -> conservatively hard-blocked"
make_gh open; write_pending
run_hook $'cat <<\'EOF\'\ngh pr merge 999 --merge --repo owner/repo\nEOF' >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "heredoc literal hard-blocked" || bad "exit $rc (want 2)"

echo "[13c] OPEN escaped dynamic eval merge -> hard-blocked"
make_gh open; write_pending
run_hook "m=gh\\ pr\\ merge\\ 999\\ --merge\\ --repo\\ owner/repo; eval \"\$m\"" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "escaped dynamic eval hard-blocked" || bad "exit $rc (want 2)"

echo "[13d] OPEN escaped dynamic bash -c merge -> hard-blocked"
make_gh open; write_pending
run_hook "m=gh\\ pr\\ merge\\ 999\\ --merge\\ --repo\\ owner/repo; bash -c \"\$m\"" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "escaped dynamic bash -c hard-blocked" || bad "exit $rc (want 2)"

echo "[13e] PR comment body mentioning merge -> no hard block"
make_gh open; write_pending
out="$(run_hook "bash -c 'gh pr comment 999 --body merge'")"; rc=$?
[ "$rc" -eq 0 ] && ok "comment body not treated as merge" || bad "exit $rc (want 0)"
printf '%s' "$out" | grep -q additionalContext && ok "comment body still gets reminder" || bad "comment body reminder missing"

echo "[13f] target repo pending state via cd + bash -c -> hard-blocked"
make_gh open
rm -f "$PENDING" "$CACHE"
write_target_pending
run_hook "cd '$TARGET_WORK' && bash -c 'gh pr merge 999 --merge --repo owner/repo'" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "target pending state hard-blocked" || bad "exit $rc (want 2)"

echo "[13g] nested shell escaped dynamic eval merge -> hard-blocked"
make_gh open; write_pending
run_hook "bash -c 'm=gh\\ pr\\ merge\\ 999\\ --merge\\ --repo\\ owner/repo; eval \"\$m\"'" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "nested escaped dynamic eval hard-blocked" || bad "exit $rc (want 2)"

echo "[13h] nested shell target repo pending state -> hard-blocked"
make_gh open
rm -f "$PENDING" "$CACHE"
write_target_pending
run_hook "bash -c 'cd \"$TARGET_WORK\" && gh pr merge 999 --merge --repo owner/repo'" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "nested target pending state hard-blocked" || bad "exit $rc (want 2)"

echo "[13i] multi-merge command without local pending state -> hard-blocked"
make_gh open
rm -f "$PENDING" "$CACHE" "$TARGET_PENDING" "$TARGET_CACHE"
run_hook "cd '$TARGET_WORK' && gh pr merge 123 --merge --repo owner/repo; gh pr merge 999 --merge --repo owner/repo" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "multi-merge hard-blocked before state rebind" || bad "exit $rc (want 2)"

echo "[14] gh failure -> fail-open (still warns, keeps state)"
make_gh FAIL; write_pending
out="$(run_hook "git status")"; rc=$?
printf '%s' "$out" | grep -q additionalContext && ok "fail-open banner" || bad "banner missing on gh failure"
[ -f "$PENDING" ] && ok "pending kept on gh failure" || bad "pending deleted on gh failure"

echo "[15] OPEN same PR + redirect before target -> hard-blocked"
make_gh open; write_pending
run_hook "gh pr merge --repo owner/repo >/tmp/out 999 --merge" >/dev/null; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "redirect-before-target same PR hard-blocked"
else
  bad "exit $rc (want 2)"
fi

echo "[16] fresh open cache honoured -> gh skipped (gh says closed, cache says open)"
make_gh closed; write_pending; seed_cache open 5
out="$(run_hook "git status")"; rc=$?
[ -f "$PENDING" ] && ok "cache hit: gh not consulted, pending kept" || bad "cache ignored (pending purged)"
printf '%s' "$out" | grep -q additionalContext && ok "banner from cache" || bad "banner missing"

echo "[17] stale cache refreshed -> purge (gh says closed)"
make_gh closed; write_pending; seed_cache open 1000
run_hook "git status" >/dev/null; rc=$?
[ ! -f "$PENDING" ] && ok "stale cache refreshed -> purged" || bad "stale cache not refreshed"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
