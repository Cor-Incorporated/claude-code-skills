#!/usr/bin/env bash
# Issue #390: forked sessions inherit cumulative tokens.  A clear user resume
# after a session/model transition starts a new budget epoch, without relaxing
# no-progress or iteration stops.  HOME and ledger are isolated from real runs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/codex/h1-stall-runtime.sh"
LIB="$ROOT/scripts/lib/h1-runtime.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export AIDD_LEDGER_SOURCE=test
mkdir -p "$SB/.claude/hooks/lib" "$SB/sessions/2026/09/23"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/.claude/hooks/lib/aidd-ledger.sh"
LEDGER="$SB/.claude/hooks/ledger/guard-ledger.jsonl"
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
rollout() { # The suffix mirrors a continued fragment missed by the old SID glob.
  if [[ "$1" == fork ]]; then
    printf '%s/sessions/2026/09/23/rollout-2026-09-23T00-00-00-fork_continued.jsonl' "$SB"
  else
    printf '%s/sessions/2026/09/23/rollout-2026-09-23T00-00-00-%s.jsonl' "$SB" "$1"
  fi
}
usage() { # session, model, input, output; event_msg is cumulative and may lag.
  cat >"$(rollout "$1")" <<EOF
{"type":"session_meta","payload":{"model":"$2"$( [[ "$1" == fork ]] && printf ',"forked_from_id":"old"' )}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":$3,"cached_input_tokens":0,"output_tokens":$4,"total_tokens":$(($3+$4))}}}}
EOF
}
record() { # session, response id, turn id, model, input, output, thread total
  cat >>"$(rollout "$1")" <<EOF
{"type":"turn_context","payload":{"turn_id":"$3","model":"$4"}}
{"type":"token_usage_record","payload":{"response_id":"$2","turn_id":"$3","usage":{"input_tokens":$5,"cached_input_tokens":0,"output_tokens":$6,"total_tokens":$(($5+$6))},"thread_token_usage":{"total_tokens":$7}}}
EOF
}
event() { # delegation, event, session, model, turn, prompt/command, extra env...
  local delegation="$1" kind="$2" sid="$3" model="$4" turn="$5" body="$6"
  shift 6
  python3 - "$kind" "$sid" "$model" "$turn" "$body" "$(rollout "$sid")" <<'PY' |
import json,sys
kind,sid,model,turn,body,transcript=sys.argv[1:]
d={"hook_event_name":kind,"session_id":sid,"model":model,"turn_id":turn,"cwd":"/tmp","transcript_path":transcript}
if kind == "UserPromptSubmit": d["prompt"]=body
elif kind == "PreToolUse": d["tool_input"]={"command":body}
elif kind == "SessionStart": d["source"]=body
print(json.dumps(d,ensure_ascii=False))
PY
  env HOME="$SB" CODEX_H1_DELEGATION="$delegation" \
    CODEX_H1_SESSIONS_DIR="$SB/sessions" CODEX_H1_BUDGET_USD=5 \
    "$@" bash "$HOOK"
}
decision() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")'
}
field() { # delegation, Python expression using s
  python3 - "$SB/.codex/hooks/h1-state/$1.json" "$2" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
print(eval(sys.argv[2],{"s":s}))
PY
}
check() { # expected, description, output
  local expected="$1" description="$2" out="$3" got
  got="$(printf '%s' "$out" | decision)"
  [[ "$got" == "$expected" ]] && ok "$description" || bad "$description (got $got)"
}

# 4M+400k is estimated at $9.00 with the known max rate.
usage old gpt-6-sol 4000000 400000
record old old-response t1 gpt-6-sol 4000000 400000 4400000
out="$(event shared PreToolUse old gpt-6-sol t1 'pwd')"
check deny 'Sol reaches the $5 cap' "$out"
[[ "$(field shared 's["last_block_rule"]')" == budget-cap ]] && ok 'block history recorded' || bad 'block history absent'

# New fork begins at exactly the parent cumulative count, not zero.  Its first
# user prompt is an explicit continuation.  The same delegation ID is reused
# here to exercise the stale watchdog state, the harder case.
usage fork gpt-6-sol 4000000 400000
event shared UserPromptSubmit fork gpt-6-sol t2 '作業を続けて下さい' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'explicit fork creates one budget epoch' || bad 'fork did not reset epoch'
[[ "$(field shared 's["last_block_rule"]')" == budget-cap ]] && ok 'history is retained' || bad 'history was erased'
watch="$(HOME="$SB" CODEX_H1_BUDGET_USD=5 bash -c 'source "$1"; h1_check shared' bash "$LIB")"
[[ -z "$watch" ]] && ok 'watchdog agrees with resumed epoch before tool call' || bad "watchdog returned stale rule $watch"
# Actual fork first response: event_msg.total may still equal the parent total,
# while token_usage_record.usage is 194323 fresh tokens. It must be charged.
record fork fork-first t2 gpt-6-sol 190380 3943 4594323
out="$(event shared PreToolUse fork gpt-6-sol t2 'pwd')"
check allow 'inherited total excluded and first response charged' "$out"
[[ "$(field shared 's["budget_epoch_spend_usd"]')" == 0.277405 ]] && ok 'fork first 194323 tokens are charged' || bad 'fork first response was not charged'
record fork fork-second t2 gpt-6-sol 2500000 250000 7344323
# Duplicated record and lagging cumulative token_count must not charge twice.
record fork fork-second t2 gpt-6-sol 2500000 250000 7344323
out="$(event shared PreToolUse fork gpt-6-sol t2 'git status')"
check deny 'new epoch spend reaches cap' "$out"
[[ "$(field shared 's["budget_epoch_spend_usd"]')" == 5.902405 ]] && ok 'epoch spend counts unique response ids once' || bad 'epoch delta is wrong'
before="$(field shared 's["spend_usd"]')"
python3 - "$(rollout fork)" <<'PY'
import sys
with open(sys.argv[1], 'a') as f:
    f.write('{"type":"response_item","padding":"' + 'x'*1200000 + '"}\n')
PY
event shared PreToolUse fork gpt-6-sol t2 'ls -la' >/dev/null
[[ "$(field shared 's["spend_usd"]')" == "$before" ]] && ok 'large unrelated transcript gap does not reprice old usage' || bad 'large gap repriced old usage'

# Same-session model change without user input never resets.  An unrelated
# user prompt also leaves the stopped epoch intact.
event shared UserPromptSubmit fork gpt-6-luna t3 '現在の状態を説明して' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'unrelated prompt does not reset' || bad 'unrelated prompt reset budget'
event shared UserPromptSubmit fork gpt-6-luna t3a '続けないで下さい' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'negated continuation does not reset' || bad 'negated continuation reset budget'
event shared UserPromptSubmit fork gpt-6-luna t3b '「続けて」と言った意味を説明して' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'quoted continuation does not reset' || bad 'quoted continuation reset budget'
for prompt in '続けてもいいですか？' '続けるには何が必要？' '続けてと表示された理由を教えて' '続けてくださいとの表示を見ました'; do
  event shared UserPromptSubmit fork gpt-6-luna t3q "$prompt" >/dev/null
done
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'questions and descriptions do not authorize reset' || bad 'non-imperative text reset budget'
event shared SessionStart fork gpt-6-luna t3 compact >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 1 ]] && ok 'automatic compact does not reset' || bad 'compact reset budget'
out="$(event shared PreToolUse fork gpt-6-sol t3 'pwd')"
check deny 'internal model change alone does not reset' "$out"

# A clear new request after changing the model resumes only the budget clock.
record fork old-epoch-final t3 gpt-6-sol 10000 1000 7355323
event shared UserPromptSubmit fork gpt-6-luna t4 'モデルをLunaに変更したので、続けて下さい' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 2 ]] && ok 'explicit model-switch continuation resets' || bad 'model-switch continuation did not reset'
[[ "$(field shared 's["budget_epoch_baseline_usd"]')" == 14.924905 ]] && ok 'pending response charged to old epoch before reset' || bad 'pending old-epoch response was lost'
event shared UserPromptSubmit fork gpt-6-luna t4 'モデルをLunaに変更したので、続けて下さい' >/dev/null
[[ "$(field shared 's["budget_epoch"]')" == 2 ]] && ok 'same turn is idempotent' || bad 'same turn reset twice'

# A fork with a different delegation state starts with inherited cumulative
# usage; explicit continuation must still create a baseline before first tool.
usage fresh gpt-6-sol 4000000 400000
event fresh UserPromptSubmit fresh gpt-6-sol t5 '続けて実装して下さい' >/dev/null
out="$(event fresh PreToolUse fresh gpt-6-sol t5 'pwd')"
check allow 'new state with inherited total does not falsely block' "$out"

# The first prompt on a fresh state may be unrelated. A later "continue" in
# the SAME session/model is not a branch or model-change authorization.
usage sameprompt gpt-6-sol 4000000 400000
event sameprompt UserPromptSubmit sameprompt gpt-6-sol ts1 '現在の状態を説明して' >/dev/null
event sameprompt UserPromptSubmit sameprompt gpt-6-sol ts2 '続けて下さい' >/dev/null
[[ "$(field sameprompt 's["budget_epoch"]')" == 0 ]] && ok 'same-session follow-up without transition does not reset' || bad 'same-session follow-up reset budget'
event sameprompt UserPromptSubmit sameprompt gpt-6-luna ts3 '続けて下さい' >/dev/null
[[ "$(field sameprompt 's["budget_epoch"]')" == 1 ]] && ok 'model transition after first prompt can reset' || bad 'model transition was forgotten'

# The two observed over-cap state shapes from Issue #390 differ in model and
# last_block_rule. Neither historical value can prevent an authorized epoch.
for spec in 'observed-sol|gpt-6-sol|25.029722|budget-cap' 'observed-luna|gpt-6-luna|25.24|'; do
  IFS='|' read -r key old_model amount last_rule <<<"$spec"
  usage "$key" "$old_model" 10000000 0
  python3 - "$SB/.codex/hooks/h1-state/$key.json" "$key" "$old_model" "$amount" "$last_rule" <<'PY'
import json,sys,time
path,sid,model,spend,last_rule=sys.argv[1:]
now=int(time.time())
json.dump({"delegation":sid,"started_ts":now-10,"last_progress_ts":now,
           "session_id":sid,"model":model,"spend_usd":float(spend),
           "spend_tokens":10000000,"tool_calls":1,"iterations":0,
           "budget_usd":25.0,"budget_source":"rollout:total_token_usage",
           "usage_snapshot":{"input_tokens":10000000,"cached_input_tokens":0,
                             "output_tokens":0,"total_tokens":10000000},
           "last_block_rule":last_rule},open(path,"w"))
PY
  if [[ "$key" == observed-sol ]]; then
    new_model=gpt-6-luna
    before="$(HOME="$SB" bash -c 'source "$1"; h1_check observed-sol' bash "$LIB")"
    [[ "$before" == budget-cap ]] && ok 'observed Sol state blocks before grant' || bad 'observed Sol state did not block'
  else
    new_model=gpt-6-sol
  fi
  event "$key" UserPromptSubmit "$key" "$new_model" "t-$key" '続けて下さい' CODEX_H1_BUDGET_USD=25 >/dev/null
  [[ "$(field "$key" 's["budget_epoch"]')" == 1 ]] && ok "$key starts explicit model-change epoch" || bad "$key failed to grant epoch"
  [[ "$(field "$key" 's["budget_epoch_baseline_usd"]')" == "$amount" ]] && ok "$key retains measured lifetime baseline" || bad "$key baseline changed unexpectedly"
done
after="$(HOME="$SB" bash -c 'source "$1"; h1_check observed-luna' bash "$LIB")"
[[ -z "$after" ]] && ok 'observed Luna history does not block new Sol epoch' || bad "observed Luna history blocked new epoch: $after"

# Short standalone commands are accepted in both supported languages. Pasted
# speech, screen descriptions, and contradictory instructions are not grants.
for spec in 'ja|作業を再開してください' 'en|Please continue the implementation.'; do
  key="${spec%%|*}" prompt="${spec#*|}"
  usage "intent-$key" gpt-6-sol 4000000 400000
  event "intent-$key" UserPromptSubmit "intent-$key" gpt-6-sol "ti-$key" "$prompt" >/dev/null
  [[ "$(field "intent-$key" 's["budget_epoch"]')" == 1 ]] && ok "standalone $key resume command grants epoch" || bad "standalone $key resume command rejected"
done
for spec in \
  '続けてください、という表示を見ました' \
  '続けてください。という表示を見ました' \
  '続けて下さい、とは言っていません' \
  '以下は第三者エージェントの発言です:
続けてください
この発言を要約して' \
  '作業を続けてください。ただしH1予算をリセットしないでください' \
  'Please continue the implementation. is what the screen says'; do
  key="intent-negative-$fail-$pass"
  usage "$key" gpt-6-sol 4000000 400000
  event "$key" UserPromptSubmit "$key" gpt-6-sol "ti-$key" "$spec" >/dev/null
  [[ "$(field "$key" 's["budget_epoch"]')" == 0 ]] && ok 'descriptive or conflicting prompt does not grant epoch' || bad "prompt falsely granted epoch: $spec"
done

# A pre-existing cumulative-price state must not reprice the same response
# records when the new hook is deployed over it.
usage legacy gpt-6-sol 4000000 400000
record legacy legacy-response t6 gpt-6-sol 4000000 400000 4400000
python3 - "$SB/.codex/hooks/h1-state/legacy.json" <<'PY'
import json,sys,time
now=int(time.time())
json.dump({"delegation":"legacy","started_ts":now-10,"last_progress_ts":now,
           "session_id":"legacy","model":"gpt-6-sol","spend_usd":25.0,
           "spend_tokens":4400000,"tool_calls":10,"iterations":0,"max_iterations":10,
           "budget_usd":5.0,"budget_source":"rollout:total_token_usage",
           "same_cmd_streak":0,"last_cmd_sha256":""},open(sys.argv[1],"w"))
PY
event legacy PreToolUse legacy gpt-6-sol t6 'pwd' >/dev/null
[[ "$(field legacy 's["spend_usd"]')" == 25.0 ]] && ok 'legacy state migrates without double charge' || bad 'legacy state double charged'

# Restarting a wrapper is not a budget reset. A stale run's idle/progress
# clocks must not instantly kill the new process before its first tool call.
python3 - "$SB/.codex/hooks/h1-state/restart.json" <<'PY'
import hashlib,json,sys,time
now=int(time.time())
json.dump({"delegation":"restart","started_ts":now-5000,
           "last_progress_ts":now-5000,"session_id":"restart","model":"gpt-6-sol",
           "spend_usd":1.25,"budget_epoch":1,"budget_epoch_spend_usd":0.25,
           "spend_tokens":1000000,"tool_calls":7,"iterations":3,
           "same_cmd_streak":3,"last_cmd_sha256":hashlib.sha256(b'pwd').hexdigest(),
           "budget_usd":5.0,"max_iterations":10,"no_progress_sec":2700},
          open(sys.argv[1],"w"))
PY
touch -t 202001010000 "$SB/.codex/hooks/h1-state/restart.json"
HOME="$SB" CODEX_H1_BUDGET_USD=6 bash -c 'source "$1"; h1_init restart; h1_check restart' bash "$LIB" >"$SB/restart-check"
[[ ! -s "$SB/restart-check" ]] && ok 'watchdog allows freshly restarted run despite old mtime' || bad 'watchdog stopped new run on old mtime'
[[ "$(field restart 's["spend_usd"]')" == 1.25 && "$(field restart 's["budget_usd"]')" == 6.0 ]] && ok 'restart keeps spend and applies current contract' || bad 'restart reset spend or ignored new contract'
out="$(event restart PreToolUse restart gpt-6-sol t7 'pwd' CODEX_H1_BUDGET_USD=6)"
check allow 'same first command after restart is not stale no-progress' "$out"

# A budget grant cannot remove a watchdog stop for another H1 condition.
python3 - "$SB/.codex/hooks/h1-state/nonbudget.json" <<'PY'
import json,sys,time
now=int(time.time())
json.dump({"delegation":"nonbudget","started_ts":now,"last_progress_ts":now,
           "session_id":"before","model":"gpt-6-sol","spend_usd":9.0,
           "budget_epoch_spend_usd":9.0,"forced_stop":"max-iterations",
           "tool_calls":3,"iterations":11,"budget_usd":5.0,"max_iterations":10},
          open(sys.argv[1],"w"))
PY
usage after gpt-6-sol 4000000 400000
event nonbudget UserPromptSubmit after gpt-6-sol t8 '続けて下さい' >/dev/null
out="$(event nonbudget PreToolUse after gpt-6-sol t8 'pwd')"
check deny 'non-budget forced stop survives budget epoch' "$out"
watch="$(HOME="$SB" bash -c 'source "$1"; h1_check nonbudget' bash "$LIB")"
[[ "$watch" == max-iterations ]] && ok 'watchdog matches non-budget forced stop' || bad 'watchdog lost non-budget stop'

# A record-free interval with increasing cumulative usage must still be billed
# as an explicitly labeled estimate. When the missing record arrives, replace
# that estimate instead of charging the same interval a second time.
usage gap gpt-6-sol 1000000 0
record gap gap-first t9 gpt-6-sol 1000000 0 1000000
event gap PreToolUse gap gpt-6-sol t9 'pwd' >/dev/null
cat >>"$(rollout gap)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":4000000}}}}
EOF
out="$(event gap PreToolUse gap gpt-6-sol t9 'git status')"
check deny 'missing response record uses cumulative delta estimate' "$out"
[[ "$(field gap 's["spend_usd"]')" == 5.0 ]] && ok 'record gap charges $3.75 delta' || bad 'record gap undercounted'
[[ "$(field gap '"record-gap-estimate" in s["budget_source"]')" == True ]] && ok 'gap estimate is labeled' || bad 'gap estimate source hidden'
record gap gap-late t9 gpt-6-sol 3000000 0 4000000
event gap PreToolUse gap gpt-6-sol t9 'ls -la' >/dev/null
[[ "$(field gap 's["spend_usd"]')" == 5.0 ]] && ok 'late record reconciles without double charge' || bad 'late record double charged'

# If only one of three missing million-token responses arrives, the other two
# million remain estimated and the cap must stay active.
usage stagger gpt-6-sol 1000000 0
record stagger stagger-first ts gpt-6-sol 1000000 0 1000000
event stagger PreToolUse stagger gpt-6-sol ts 'pwd' >/dev/null
cat >>"$(rollout stagger)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":4000000}}}}
EOF
out="$(event stagger PreToolUse stagger gpt-6-sol ts 'git status')"
check deny 'three million missing tokens reach budget cap' "$out"
record stagger stagger-second ts gpt-6-sol 1000000 0 2000000
out="$(event stagger PreToolUse stagger gpt-6-sol ts 'ls')"
check deny 'one late response leaves two million provisional tokens' "$out"
[[ "$(field stagger 's["spend_usd"]')" == 5.0 ]] && ok 'partial late record cannot lower guarded spend' || bad 'partial late record lowered spend'
[[ "$(field stagger 's["meter_gap_estimate_tokens"]')" == 2000000 ]] && ok 'unresolved provisional tokens remain tracked' || bad 'unresolved provisional tokens were lost'
record stagger stagger-third ts gpt-6-sol 2000000 0 4000000
event stagger PreToolUse stagger gpt-6-sol ts 'pwd' >/dev/null
[[ "$(field stagger 's["spend_usd"]')" == 5.0 ]] && ok 'fully late records settle estimate once' || bad 'fully late records changed guarded spend'

# One delayed old response and one fresh response can arrive together. The
# fresh response is also reflected in the cumulative counter; it cannot be
# used to clear the old provisional gap.
usage mixedgap gpt-6-sol 1000000 0
record mixedgap mg-first tmg gpt-6-sol 1000000 0 1000000
event mixedgap PreToolUse mixedgap gpt-6-sol tmg 'pwd' CODEX_H1_BUDGET_USD=6 >/dev/null
cat >>"$(rollout mixedgap)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":4000000}}}}
EOF
event mixedgap PreToolUse mixedgap gpt-6-sol tmg 'git status' CODEX_H1_BUDGET_USD=6 >/dev/null
record mixedgap mg-late tmg gpt-6-sol 1000000 0 2000000
record mixedgap mg-fresh tmg gpt-6-sol 1000000 0 3000000
cat >>"$(rollout mixedgap)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":5000000}}}}
EOF
out="$(event mixedgap PreToolUse mixedgap gpt-6-sol tmg 'ls' CODEX_H1_BUDGET_USD=6)"
check deny 'mixed late and fresh records still cross the six-dollar cap' "$out"
[[ "$(field mixedgap 's["spend_usd"]')" == 6.25 ]] && ok 'mixed late/fresh interval bills the fresh million' || bad 'mixed late/fresh interval lost fresh cost'

# Even with equal token counts, a cheap old late record cannot stand in for a
# fresh expensive response reflected only in the cumulative counter.
usage ratefloor gpt-5-mini 1000000 0
record ratefloor rf-first trf-old gpt-5-mini 1000000 0 1000000
event ratefloor PreToolUse ratefloor gpt-5-mini trf-old 'pwd' CODEX_H1_BUDGET_USD=2 >/dev/null
cat >>"$(rollout ratefloor)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":4000000}}}}
EOF
event ratefloor PreToolUse ratefloor gpt-5-mini trf-old 'git status' CODEX_H1_BUDGET_USD=2 >/dev/null
record ratefloor rf-late trf-old gpt-5-mini 1000000 0 2000000
cat >>"$(rollout ratefloor)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":5000000}}}}
EOF
out="$(event ratefloor PreToolUse ratefloor gpt-5-codex trf-new 'ls' CODEX_H1_BUDGET_USD=2 CODEX_H1_RESTRICTED_MODELS=gpt-5-codex)"
check deny 'fresh expensive event exceeds cheap delayed record' "$out"
[[ "$(field ratefloor 's["spend_usd"]')" == 2.25 ]] && ok 'event price floor preserves mixed-model charge' || bad 'mixed-model event floor undercounted'
[[ "$(field ratefloor '"event-price-floor-estimate" in s["budget_source"]')" == True ]] && ok 'event price floor is labeled' || bad 'event price floor source hidden'

usage gap2 gpt-6-sol 4000000 0
event gap UserPromptSubmit gap2 gpt-6-sol t10 '続けて下さい' >/dev/null
record gap2 new-epoch t10 gpt-6-sol 100000 0 4100000
event gap PreToolUse gap2 gpt-6-sol t10 'pwd' >/dev/null
[[ "$(field gap 's["budget_epoch_spend_usd"]')" == 0.125 ]] && ok 'old gap estimate cannot subtract from new epoch' || bad 'gap estimate crossed epoch boundary'

# Partial missing records in one interval: the observed response accounts for
# 1M of a 3M cumulative delta, so the other 2M is still budgeted as estimate.
usage partial gpt-6-sol 1000000 0
record partial part-a tp gpt-6-sol 1000000 0 1000000
event partial PreToolUse partial gpt-6-sol tp 'pwd' >/dev/null
record partial part-b tp gpt-6-sol 1000000 0 2000000
cat >>"$(rollout partial)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":4000000}}}}
EOF
out="$(event partial PreToolUse partial gpt-6-sol tp 'git status')"
check deny 'partial record gap still reaches budget' "$out"
[[ "$(field partial 's["spend_usd"]')" == 5.0 ]] && ok 'partial gap estimates missing 2M tokens' || bad 'partial gap undercounted'
[[ "$(field partial '"partial-record-gap-estimate" in s["budget_source"]')" == True ]] && ok 'partial gap source is labeled' || bad 'partial gap label missing'
record partial part-c tp gpt-6-sol 2000000 0 4000000
event partial PreToolUse partial gpt-6-sol tp 'ls -la' >/dev/null
[[ "$(field partial 's["spend_usd"]')" == 5.0 ]] && ok 'late partial record reconciles estimate' || bad 'late partial record double charged'

# The active model must not reprice all past responses after Sol/Luna changes.
# Known model rates make misattribution visible: gpt-5-codex $1.25/M input,
# gpt-5-mini $0.25/M input.
usage mixed gpt-5-codex 2000000 0
record mixed mixed-a ta gpt-5-codex 1000000 0 1000000
record mixed mixed-b tb gpt-5-mini 1000000 0 2000000
event mixed PreToolUse mixed gpt-5-codex tb 'pwd' >/dev/null
[[ "$(field mixed 's["spend_usd"]')" == 1.5 ]] && ok 'per-response models price mixed usage' || bad 'last model repriced mixed history'

# Actual observed fork surfaces are not the same counter: event_msg inherited
# 163666990, while first per-response thread_total is 165076326 and fresh usage
# is 194323. Keep both baselines inspectable.
usage realfork gpt-6-sol 160000000 3666990
cat >>"$(rollout realfork)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160000000,"cached_input_tokens":0,"output_tokens":3666990,"total_tokens":163666990},"last_token_usage":{"input_tokens":20000,"cached_input_tokens":0,"output_tokens":367,"total_tokens":20367}}}}
EOF
event realfork UserPromptSubmit realfork gpt-6-sol t11 '続けて下さい' >/dev/null
record realfork real-first t11 gpt-6-sol 190380 3943 165076326
event realfork PreToolUse realfork gpt-6-sol t11 'pwd' >/dev/null
[[ "$(field realfork 's["budget_epoch_baseline_tokens"]')" == 163666990 ]] && ok 'inherited event counter is separate baseline' || bad 'event counter baseline lost'
[[ "$(field realfork 's["budget_epoch_baseline_record_tokens"]')" == 164882003 ]] && ok 'per-response baseline is thread_total minus first usage' || bad 'per-response baseline wrong'
[[ "$(field realfork 's["budget_epoch_spend_usd"]')" == 0.277405 ]] && ok 'real fork first response billed once' || bad 'real fork first response undercounted'
record realfork real-second t11 gpt-6-sol 62470 0 165138796
cat >>"$(rollout realfork)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160062470,"cached_input_tokens":0,"output_tokens":3666990,"total_tokens":163729460}}}}
EOF
event realfork PreToolUse realfork gpt-6-sol t11 'git status' >/dev/null
before="$(field realfork 's["budget_epoch_spend_usd"]')"
cat >>"$(rollout realfork)" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":161062470,"cached_input_tokens":0,"output_tokens":3666990,"total_tokens":164729460}}}}
EOF
event realfork PreToolUse realfork gpt-6-sol t11 'ls -la' >/dev/null
python3 - "$before" "$(field realfork 's["budget_epoch_spend_usd"]')" <<'PY' && ok 'fork offset cannot suppress later unrecorded million tokens' || bad 'fork offset suppressed later usage'
import sys
assert round(float(sys.argv[2])-float(sys.argv[1]),6)==1.25,sys.argv
PY

# Lock serializes simultaneous hook invocations for the same delegation.
usage concurrent gpt-6-sol 0 0
for _ in 1 2 3 4 5 6 7 8; do
  event concurrent PreToolUse concurrent gpt-6-sol tc 'pwd' >/dev/null &
done
wait
[[ "$(field concurrent 's["tool_calls"]')" == 8 ]] && ok 'parallel PreToolUse updates are serialized' || bad 'parallel PreToolUse lost state updates'

# Ledger records reset reason and baseline without storing the raw prompt.
python3 - "$LEDGER" <<'PY' && ok 'ledger has reset reason and baseline' || bad 'ledger missing reset evidence'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
resets=[r for r in rows if r.get('component')=='H1' and r.get('event')=='measure' and r.get('rule')=='budget-epoch-reset']
assert len(resets)>=3,resets
assert all('budget_epoch_baseline_tokens' in r.get('subject',{}) for r in resets),resets
assert all('previous_budget_epoch' in r.get('subject',{}) for r in resets),resets
assert all(r.get('subject',{}).get('reset_turn_id') for r in resets),resets
assert all(r.get('subject',{}).get('scope_cwd') for r in resets),resets
assert all(r.get('detail') in ('explicit-user-resume:session','explicit-user-resume:model','explicit-user-resume:new-session') for r in resets),resets
assert not any('続けて' in json.dumps(r,ensure_ascii=False) for r in resets),resets
PY

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
