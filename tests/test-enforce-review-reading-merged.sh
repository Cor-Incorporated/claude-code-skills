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
GHBIN="$(mktemp -d)"
trap 'rm -rf "$WORK" "$GHBIN"' EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@t.t
git -C "$WORK" config user.name t
STATE_DIR="$WORK/.claude/state"
mkdir -p "$STATE_DIR"
PENDING="$STATE_DIR/pending-review-comments.json"
CACHE="$STATE_DIR/pending-review-pr-state.cache"

# gh mock: prints the configured state for any args; "FAIL" -> exit 1.
make_gh() {
  printf '#!/bin/bash\nif [ "%s" = "FAIL" ]; then exit 1; fi\necho "%s"\n' "$1" "$1" > "$GHBIN/gh"
  chmod +x "$GHBIN/gh"
}

write_pending() {
  cat > "$PENDING" <<'JSON'
{"pr":"999","repo":"owner/repo","head_sha":"abc123","total":2,"critical":1,"high":1,"classification_method":"regex","output":"[review] PR #999 Severity: CRITICAL=1 HIGH=1"}
JSON
  rm -f "$CACHE"
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
  ( cd "$WORK" && printf '{"tool_input":{"command":"%s"}}' "$1" \
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

echo "[6] gh failure -> fail-open (still warns, keeps state)"
make_gh FAIL; write_pending
out="$(run_hook "git status")"; rc=$?
printf '%s' "$out" | grep -q additionalContext && ok "fail-open banner" || bad "banner missing on gh failure"
[ -f "$PENDING" ] && ok "pending kept on gh failure" || bad "pending deleted on gh failure"

echo "[7] fresh open cache honoured -> gh skipped (gh says closed, cache says open)"
make_gh closed; write_pending; seed_cache open 5
out="$(run_hook "git status")"; rc=$?
[ -f "$PENDING" ] && ok "cache hit: gh not consulted, pending kept" || bad "cache ignored (pending purged)"
printf '%s' "$out" | grep -q additionalContext && ok "banner from cache" || bad "banner missing"

echo "[8] stale cache refreshed -> purge (gh says closed)"
make_gh closed; write_pending; seed_cache open 1000
run_hook "git status" >/dev/null; rc=$?
[ ! -f "$PENDING" ] && ok "stale cache refreshed -> purged" || bad "stale cache not refreshed"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
