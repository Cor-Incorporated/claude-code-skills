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

# Escapes from the #457 review: a declaration can only list repositories under ~/Developer, and the
# file name and content are fixed in the applier.
mkdir -p "$H/outside/victim/.git" "$H/Developer/linked/.git"
ln -s "$H/outside" "$H/Developer/linked/.claude"
python3 - "$DECL" "$SB/evil.json" "$H" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["repos"] = ["~/../outside/victim", sys.argv[3] + "/outside/victim", "~/Developer/linked", "~/Developer/claude-code-skills"]
json.dump(d, open(sys.argv[2], "w"))
PY
out="$(python3 "$APPLY" "$SB/evil.json" --home "$H")"; rc=$?
[[ $rc -eq 0 && ! -e "$H/outside/victim/.claude" && ! -e "$H/outside/sessions" ]] \
  && ok "O1 ~/../, an absolute path and a .claude symlink out of the repository write nothing outside" \
  || bad "O1 escape" "rc=$rc $(ls -R "$H/outside" 2>/dev/null | tr '\n' ' ') $out"
for field in file content; do
  python3 - "$DECL" "$SB/evil-$field.json" "$field" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[3] == "file":
    d["file"] = "../../.claude/settings.local.json"
else:
    d["content"] = {"env": {"HARNESS_RUNTIME_FLOOR_EGRESS": "off"}}
json.dump(d, open(sys.argv[2], "w"))
PY
  out="$(python3 "$APPLY" "$SB/evil-$field.json" --home "$H")"; rc=$?
  [[ $rc -eq 2 && ! -e "$H/.claude/settings.local.json" ]] \
    && ok "O1 a declaration that changes the $field is refused (rc=2, nothing written)" || bad "O1 $field" "rc=$rc $out"
done
mkdir -p "$H/Developer/broken/.git" && printf 'x' >"$H/Developer/broken/.claude"
python3 - "$DECL" "$SB/broken.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["repos"] = ["~/Developer/broken", "~/Developer/ai-cluster"]
json.dump(d, open(sys.argv[2], "w"))
PY
out="$(python3 "$APPLY" "$SB/broken.json" --home "$H")"; rc=$?
[[ $rc -eq 0 && "$out" == *"broken: NotADirectoryError"* && "$out" == *"ai-cluster: already"* ]] \
  && ok "O1 an error in one repository is reported and the next one still runs (rc=0)" || bad "O1 per-repo error" "rc=$rc $out"

# --- O2 ---------------------------------------------------------------------
grep -q 'python3 "$REPO_DIR/scripts/apply-auto-broadcast-optout.py" "$REPO_DIR/config/auto-broadcast-optout.json"' "$ROOT/setup.sh" \
  && ok "O2 setup.sh applies the declaration" || bad "O2 wiring" "setup.sh does not call the applier with the declaration"
# setup.sh runs under set -e: a failing applier must not stop steps 7-9.
grep -A1 'scripts/apply-auto-broadcast-optout.py' "$ROOT/setup.sh" | grep -q '|| echo' \
  && ok "O2 a failing applier does not stop setup.sh (|| guard)" || bad "O2 abort guard" "step 6b has no || guard under set -e"

# --- O3 ---------------------------------------------------------------------
# The installed plugin is the one installed_plugins.json records, not the highest cache directory:
# after a switch both 5.16.0/ and 5.16.0-cor.1/ stay, and `sort -V` puts "5.16.0/" last (#456 review).
PLUGIN_ROOT="$(python3 -c 'import json,os,sys
try:
    d = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
    print(d["plugins"]["harness@claude-code-harness-marketplace"][0]["installPath"])
except Exception:
    sys.exit(0)' 2>/dev/null)"
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
