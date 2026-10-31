#!/usr/bin/env bash
# H17 DOT-INC-026 ↔ ADR-015 (aidd-governance#235): a push/merge claim is bound by the session's own push/merge OR by
# a read whose own output shows the merged pull request / the pushed commit.
#
# Origin (2026-10-31): the orchestrator relays other lanes' merges and was blocked 5+ times with
# "push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)", although it had read
# every merge back with `gh pr view … --json state,mergeCommit`.
#
# Each case drives the real hook (hooks/aidd-cc-claude.sh) with PostToolUse rows and then a Stop. The last case is
# the link: the same reporter session through a mutant whose read acceptance is removed must block, and the line
# names both results.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test AIDD_LEDGER_PATH="$SB/ledger.jsonl" AIDD_CC_STATE_DIR="$SB/state" AIDD_CC_MAX_STOP_BLOCKS=99
HOOK="$ROOT/hooks/aidd-cc-claude.sh"
SHA=691a9d13c5b1f0e1d2a3b4c5d6e7f8091a2b3c4d
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

post() {  # hook session command stdout [rc]
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": sys.argv[1], "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[2]},
                  "tool_response": {"exit_code": int(sys.argv[4]), "stdout": sys.argv[3]}}))' "$2" "$3" "$4" "${5:-0}" \
    | bash "$1" >/dev/null
}
stop() {  # hook session text
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[1], "last_assistant_message": sys.argv[2]}))' "$2" "$3" \
    | bash "$1"
}
REPORT=$'Lane L3: Cor-Incorporated/ai-cluster#606 is merged (691a9d1).\nStatus: partial'
PUSHED=$'Lane L1 pushed feat/l1-practical-bench to origin.\nStatus: partial'
blocked() { printf '%s' "$1" | grep -q 'DOT-INC-026'; }

# R1 a merge read whose output says MERGED binds the relayed merge
post "$HOOK" r1 "gh pr view 606 --repo Cor-Incorporated/ai-cluster --json state,mergeCommit" \
  "{\"mergeCommit\":{\"oid\":\"$SHA\"},\"state\":\"MERGED\"}"
o="$(stop "$HOOK" r1 "$REPORT")"
blocked "$o" && bad "R1 gh pr view … MERGED binds a relayed merge" "$o" || ok "R1 gh pr view … MERGED binds a relayed merge"

# R2 the same read of an OPEN pull request does not
post "$HOOK" r2 "gh pr view 606 --repo Cor-Incorporated/ai-cluster --json state,mergeCommit" '{"mergeCommit":null,"state":"OPEN"}'
o="$(stop "$HOOK" r2 "$REPORT")"
blocked "$o" && ok "R2 an OPEN pull request read does not bind a merge claim" || bad "R2 OPEN read" "$o"

# R3 output faked by a later segment does not count
post "$HOOK" r3 "gh pr view 606 --json state --jq .state && echo MERGED" $'OPEN\nMERGED'
o="$(stop "$HOOK" r3 "$REPORT")"
blocked "$o" && ok "R3 'gh pr view … && echo MERGED' does not count" || bad "R3 faked output" "$o"

# R4 a failed read does not count
post "$HOOK" r4 "gh pr view 606 --json state --jq .state" "MERGED" 1
o="$(stop "$HOOK" r4 "$REPORT")"
blocked "$o" && ok "R4 a read with rc=1 does not count" || bad "R4 rc=1" "$o"

# R5 cd then a read counts
post "$HOOK" r5 "cd ~/Developer/ai-cluster && gh pr view 606 --json state --jq .state" "MERGED"
o="$(stop "$HOOK" r5 "$REPORT")"
blocked "$o" && bad "R5 'cd <dir> && gh pr view …' binds" "$o" || ok "R5 'cd <dir> && gh pr view …' binds"

# R6 gh api pulls/<n> with "merged": true
post "$HOOK" r6 "gh api repos/Cor-Incorporated/ai-cluster/pulls/606" "{\"number\":606,\"merged\":true,\"merged_at\":\"2026-10-31T08:04:21Z\"}"
o="$(stop "$HOOK" r6 "$REPORT")"
blocked "$o" && bad "R6 gh api …/pulls/<n> merged binds" "$o" || ok "R6 gh api …/pulls/<n> merged binds"

# R7 a push read: gh api …/commits/<ref> printing the sha binds a relayed push
post "$HOOK" r7 "gh api repos/Cor-Incorporated/ai-cluster/commits/feat/l1-practical-bench --jq .sha" "$SHA"
o="$(stop "$HOOK" r7 "$PUSHED")"
blocked "$o" && bad "R7 gh api …/commits/<ref> binds a relayed push" "$o" || ok "R7 gh api …/commits/<ref> binds a relayed push"

# R8 git ls-remote printing the ref binds a relayed push
post "$HOOK" r8 "git ls-remote origin refs/heads/feat/l1-practical-bench" "$SHA	refs/heads/feat/l1-practical-bench"
o="$(stop "$HOOK" r8 "$PUSHED")"
blocked "$o" && bad "R8 git ls-remote binds a relayed push" "$o" || ok "R8 git ls-remote binds a relayed push"

# R9 an unrelated command still leaves the claim unbound (unchanged behaviour)
post "$HOOK" r9 "ls -la" "x"
o="$(stop "$HOOK" r9 "$REPORT")"
blocked "$o" && ok "R9 without a push, merge or read the claim is still blocked" || bad "R9 unbound" "$o"

# R10 the session's own push still binds (unchanged behaviour)
post "$HOOK" r10 "git push origin feat/x" "To github.com:o/r.git"
o="$(stop "$HOOK" r10 "$PUSHED")"
blocked "$o" && bad "R10 the session's own git push binds" "$o" || ok "R10 the session's own git push binds"

# R11 a read of the wrong kind: gh pr view printing only a sha (no state) does not bind a merge
post "$HOOK" r11 "gh pr view 606 --json headRefOid --jq .headRefOid" "$SHA"
o="$(stop "$HOOK" r11 "$REPORT")"
blocked "$o" && ok "R11 gh pr view without a merged state does not bind" || bad "R11 headRefOid only" "$o"

# --- link: the reporter case through a mutant without the read acceptance -----------------------------------
MUT="$SB/mutant"
mkdir -p "$MUT/lib"
cp "$ROOT/hooks/aidd-cc-claude.sh" "$MUT/aidd-cc-claude.sh"
cp "$ROOT"/hooks/lib/aidd_cc*.py "$ROOT/hooks/lib/aidd-cc-adapter.sh" "$MUT/lib/"
python3 - "$MUT/lib/aidd_cc_controls.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '    """A successful read whose output shows a merged pull request or a pushed commit."""\n'
assert old in s, "mutation anchor missing"
s = s.replace(old, old + "    return False  # MUTANT: reads are not evidence\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
export AIDD_CC_STATE_DIR="$SB/state-mutant"
post "$MUT/aidd-cc-claude.sh" m1 "gh pr view 606 --repo Cor-Incorporated/ai-cluster --json state,mergeCommit" \
  "{\"mergeCommit\":{\"oid\":\"$SHA\"},\"state\":\"MERGED\"}"
om="$(stop "$MUT/aidd-cc-claude.sh" m1 "$REPORT")"
export AIDD_CC_STATE_DIR="$SB/state"
real=allow; blocked "$(stop "$HOOK" r1 "$REPORT")" && real=block
mutant=allow; blocked "$om" && mutant=block
[[ "$real" == allow && "$mutant" == block ]] \
  && ok "L1 link: reporter case real=$real mutant(no read acceptance)=$mutant" \
  || bad "L1 link" "reporter case real=$real mutant(no read acceptance)=$mutant (want allow / block)"

echo "---"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
