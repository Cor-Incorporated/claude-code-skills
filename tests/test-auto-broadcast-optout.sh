#!/usr/bin/env bash
# 宣言 (config/auto-broadcast-optout.json) ↔ 適用 (scripts/apply-auto-broadcast-optout.py,
# setup.sh step 6b) ↔ 強制 (harness plugin の bin/harness hook auto-broadcast) を結ぶ。
#
# 起点 (aidd-governance#230 F8, 2026-10-31 owner approved): plugin の自動ブロードキャストが
# .md/.sh/.go を書くたびに共有 broadcast.md へ書き込み、Claude Code の memory パス
# (~/.claude/projects/*/memory/) まで他セッションへ流していた。2026-10-31 実測で 4 repo に
# 334〜500 行、そのうち memory パス 31〜44 行。
#
# 層:
#   O1 適用: 宣言した repo にだけ宣言した内容を書く。既にある別の内容は残して両方の値を出す。
#      git でない repo は飛ばす。2 回目は何も変えない。--check は欠けていれば rc=1
#   O2 配線: setup.sh が宣言ファイルを渡して適用器を呼ぶ
#   O3 実 enforcer: opt-out のある checkout では broadcast しない。無ければする (片側変異)。
#      5.16.0-cor.1 以降は ~/.claude/projects/ のパスと project 外のファイルも流さない
# O3 は plugin (または HARNESS_FLOOR_BIN の build) がある機械だけで走る。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECL="$ROOT/config/auto-broadcast-optout.json"
APPLY="$ROOT/scripts/apply-auto-broadcast-optout.py"

pass=0
fail=0
skip=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }
skp() { echo "SKIP: $1"; skip=$((skip + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
H="$SB/home"
mkdir -p "$H/Developer/claude-code-skills/.git" "$H/Developer/ai-cluster/.git" "$H/Developer/corsweb" "$H/Developer/unlisted/.git"
mkdir -p "$H/Developer/grift-cli/.git/" "$H/Developer/grift-cli/.claude/sessions"
printf '{"enabled": true}\n' >"$H/Developer/grift-cli/.claude/sessions/auto-broadcast.json"

# --- O1 ---------------------------------------------------------------------
out="$(python3 "$APPLY" "$DECL" --home "$H" --check)"; rc=$?
[[ $rc -eq 1 && "$out" == *"claude-code-skills: .claude/sessions/auto-broadcast.json missing"* ]] \
  && ok "O1 --check reports a listed checkout without the file (rc=1)" || bad "O1 check before" "rc=$rc $out"
[[ ! -e "$H/Developer/claude-code-skills/.claude/sessions/auto-broadcast.json" ]] \
  && ok "O1 --check writes nothing" || bad "O1 check wrote" "file exists after --check"

out="$(python3 "$APPLY" "$DECL" --home "$H")"; rc=$?
f="$H/Developer/claude-code-skills/.claude/sessions/auto-broadcast.json"
[[ $rc -eq 0 && "$(cat "$f" 2>/dev/null)" == '{"enabled": false}' ]] \
  && ok "O1 a listed git checkout gets the declared content" || bad "O1 apply" "rc=$rc content='$(cat "$f" 2>/dev/null)' $out"
[[ "$out" == *"grift-cli: left as is, it holds {\"enabled\": true} (declared {\"enabled\": false})"* \
   && "$(cat "$H/Developer/grift-cli/.claude/sessions/auto-broadcast.json")" == '{"enabled": true}' ]] \
  && ok "O1 a different existing choice is kept and both values are printed" || bad "O1 keep" "$out"
[[ "$out" == *"corsweb: not a git checkout here, skipped"* && ! -e "$H/Developer/corsweb/.claude" ]] \
  && ok "O1 a listed path that is not a git checkout is skipped" || bad "O1 non-git" "$out"
[[ ! -e "$H/Developer/unlisted/.claude" ]] && ok "O1 an unlisted repository is never touched" || bad "O1 unlisted" "unlisted got a file"
out2="$(python3 "$APPLY" "$DECL" --home "$H")"
[[ "$out2" == *"claude-code-skills: already"* && "$out2" != *"+ "* ]] \
  && ok "O1 a second run changes nothing" || bad "O1 idempotent" "$out2"
out="$(python3 "$APPLY" "$DECL" --home "$H" --check)"; rc=$?
[[ $rc -eq 0 ]] && ok "O1 --check passes once applied (rc=0)" || bad "O1 check after" "rc=$rc $out"

# --- O2 ---------------------------------------------------------------------
grep -q 'python3 "$REPO_DIR/scripts/apply-auto-broadcast-optout.py" "$REPO_DIR/config/auto-broadcast-optout.json"' "$ROOT/setup.sh" \
  && ok "O2 setup.sh applies the declaration" || bad "O2 wiring" "setup.sh does not call the applier with the declaration"

# --- O3 ---------------------------------------------------------------------
PLUGIN_ROOT="$(ls -d "$HOME"/.claude/plugins/cache/claude-code-harness-marketplace/harness/*/ 2>/dev/null | sort -V | tail -1)"
BIN="${HARNESS_FLOOR_BIN:-${PLUGIN_ROOT%/}/bin/harness}"
if [[ ! -x "$BIN" ]]; then
  skp "O3 harness plugin not installed on this machine"
else
  VERSION="$("$BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)"
  echo "enforcer: $BIN (version ${VERSION:-unknown})"
  R="$SB/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  broadcast() { # $1 = file_path → prints the hook's additionalContext
    python3 -c 'import json,sys;print(json.dumps({"session_id":"optout-test","cwd":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[2]}}))' "$R" "$1" \
      | (cd "$R" && env -u HARNESS_PROJECT_ROOT -u PROJECT_ROOT CLAUDE_PROJECT_DIR="$R" "$BIN" hook auto-broadcast 2>/dev/null) \
      | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
print((json.loads(raw).get("hookSpecificOutput") or {}).get("additionalContext","") if raw else "")'
  }
  ctx="$(broadcast "docs/plan.md")"
  [[ -n "$ctx" ]] && ok "O3 mutation side: without the opt-out the plugin broadcasts an .md edit" || bad "O3 baseline" "no broadcast without the opt-out (the check below would prove nothing)"
  mkdir -p "$R/.claude/sessions"
  python3 -c 'import json,sys;json.dump(json.load(open(sys.argv[1]))["content"],open(sys.argv[2],"w"))' "$DECL" "$R/.claude/sessions/auto-broadcast.json"
  ctx="$(broadcast "docs/plan.md")"
  [[ -z "$ctx" ]] && ok "O3 with the declared opt-out the plugin stays silent" || bad "O3 opt-out" "still broadcast: $ctx"
  rm -f "$R/.claude/sessions/auto-broadcast.json"
  if [[ "$VERSION" == *-cor.* ]]; then
    ctx="$(broadcast "$HOME/.claude/projects/-Users-x-Developer-repo/memory/feedback_x.md")"
    [[ -z "$ctx" ]] && ok "O3 ($VERSION) a Claude Code memory path is never broadcast" || bad "O3 memory path" "$ctx"
    ctx="$(broadcast "$SB/elsewhere/report.md")"
    [[ -z "$ctx" ]] && ok "O3 ($VERSION) a file outside the project is never broadcast" || bad "O3 outside" "$ctx"
  else
    ctx="$(broadcast "$HOME/.claude/projects/-Users-x-Developer-repo/memory/feedback_x.md")"
    [[ -n "$ctx" ]] && ok "O3 ($VERSION) memory paths still broadcast here without the opt-out (the leak 5.16.0-cor.1 closes)" || bad "O3 memory path before" "not broadcast on $VERSION"
    skp "O3 memory and outside-project exclusions need a 5.16.0-cor build (run with HARNESS_FLOOR_BIN)"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
