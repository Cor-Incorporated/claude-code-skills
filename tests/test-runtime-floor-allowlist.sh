#!/usr/bin/env bash
# 宣言 (config/runtime-floor-allowlist.json) ↔ 配備値 (settings.json env) ↔
# 強制 (harness plugin の bin/harness hook pre-tool) を機械的に結ぶ。
#
# 起点 (2026-10-30 harness-pdca F1/F2): 値の無い雛形 smb-credentials.cred.template の
# cat が RUNTIME_FLOOR:secret-read で止まった。許可は plugin の
# HARNESS_RUNTIME_FLOOR_SECRET_ALLOW でしか表せないが、実 enforcer に当てると
# 許可した名前に秘密を空白なしで連結した形 (cat ~/.aws/credentials;x.template) まで
# 通ることが分かった (#446 review)。だから secret_read も egress も今は enforced=false。
#
# 層:
#   L1 enforced=false の区分は settings.json に env を置かない (宣言だけで効いた
#      ことにしない)。enforced=true なら値が一字一句一致する。両方の値を挙げて落ちる
#   L2 実 enforcer: 現在 (env なし) の判定と、提案中の env での判定を両方記録する。
#      must_deny は両方で deny、observed_false_positives は env なしで deny (誤検知の
#      記録) / env ありで allow、composition_opened_by_proposal は env ありで allow
#      (= enforced にしない理由。upstream の tokenizer が直ればここが red になり、
#      宣言を enforced=true に変える合図になる)
#   L3 egress: plugin に knob が無い。HARNESS_RUNTIME_FLOOR_EGRESS=off も提案中の env も
#      settings に置かない
#   L4 settings.json の enabledPlugins ↔ インストール済み plugin ↔ live の settings.json
#      (2026-10-30 実測: repo は claude-code-harness@…、実体は harness@…。この
#       settings.json を setup.sh で配ると床ごと plugin が無効になる)
#
# L2 と live 側の L4 は plugin がインストールされた機械だけで走る (CI では SKIP と数える)。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECL="$ROOT/config/runtime-floor-allowlist.json"
SETTINGS="$ROOT/settings.json"

pass=0
fail=0
skip=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }
skp() { echo "SKIP: $1"; skip=$((skip + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# --- L1 / L3: declaration ↔ settings.json ------------------------------------
decl_check() { # $1 = settings path → prints problems, empty when consistent
  python3 - "$DECL" "$1" <<'PY'
import json, sys
decl = json.load(open(sys.argv[1]))
env = json.load(open(sys.argv[2])).get("env", {})
problems = []
sr = decl["secret_read"]
key = sr["env"]
want = ",".join(a["pattern"] for a in sr["proposed_allow"])
if sr["enforced"]:
    if env.get(key) != want:
        problems.append(f"secret_read enforced: declared={want!r} settings.json={env.get(key)!r}")
elif key in env:
    problems.append(f"secret_read enforced=false but settings.json sets {key}={env[key]!r}")
eg = decl["egress"]
if str(env.get("HARNESS_RUNTIME_FLOOR_EGRESS", "")).strip().lower() == "off":
    problems.append("settings.json sets HARNESS_RUNTIME_FLOOR_EGRESS=off (disables the whole category)")
if not eg["enforced"] and eg["proposed_env"] in env:
    problems.append(f"{eg['proposed_env']} is in settings.json but egress.enforced=false")
print("; ".join(problems))
PY
}
out="$(decl_check "$SETTINGS")"
[[ -z "$out" ]] && ok "L1/L3 settings.json carries no floor allowlist that the declaration does not enforce" || bad "L1/L3" "$out"

python3 - "$SETTINGS" "$SB/settings-mutant.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["env"]["HARNESS_RUNTIME_FLOOR_SECRET_ALLOW"] = "*.template"
json.dump(s, open(sys.argv[2], "w"))
PY
out="$(decl_check "$SB/settings-mutant.json")"
[[ -n "$out" ]] && ok "L1 one-sided mutation (env added to settings.json only) goes red: $out" || bad "L1 mutation" "not detected"

# --- L4 fixtures: the same script setup.sh runs (scripts/check-plugin-ids.py) ---
C="$ROOT/scripts/check-plugin-ids.py"
j() { printf '%s' "$2" >"$SB/$1.json"; }
j inst '{"plugins":{"harness@m":[{}],"cc-harness@n":[{}],"harness@new":[{}],"git@o":[{}],"gopls-lsp@o":[{}],"swift-lsp@o":[{}]}}'
l4() { # $1 = name, $2 = repo enabled json, $3 = live enabled json, $4 = want rc, $5 = must contain
  j repo "{\"enabledPlugins\":$2}"; j live "{\"enabledPlugins\":$3}"
  local out rc
  out="$(python3 "$C" "$SB/repo.json" "$SB/inst.json" "$SB/live.json")"; rc=$?
  [[ $rc -eq $4 && "$out" == *"$5"* ]] && ok "L4 $1 (rc=$rc)" || bad "L4 $1" "rc=$rc want $4: $out"
}
l4 "rename inside a one-plugin marketplace is refused" '{"claude-code-harness@m":true}' '{"harness@m":true}' 1 "harness@m"
l4 "rename with unrelated names is refused" '{"claude-code-harness@n":true}' '{"cc-harness@n":true}' 1 "cc-harness@n"
l4 "marketplace rename is refused" '{"harness@old":true}' '{"harness@new":true}' 1 "harness@new"
l4 "catalog: rust-lsp missing while swift-lsp (same catalog) is live only warns" '{"rust-lsp@o":true}' '{"swift-lsp@o":true}' 0 "warning"
l4 "catalog: same marketplace, unrelated plugin only warns" '{"github@o":true}' '{"swift-lsp@o":true}' 0 "warning"
l4 "a live plugin the repo leaves off only warns" '{"git@o":true}' '{"git@o":true,"gopls-lsp@o":true}' 0 "turns off gopls-lsp@o"
j repo '{"enabledPlugins":{"claude-code-harness@m":true}}'
out="$(python3 "$C" "$SB/repo.json" "$SB/inst.json")"; rc=$?
[[ $rc -eq 0 && "$out" == *warning* ]] && ok "L4 no live settings (fresh machine) only warns" || bad "L4 no live" "rc=$rc $out"
printf 'not json' >"$SB/broken.json"
out="$(python3 "$C" "$SB/repo.json" "$SB/broken.json" "$SB/live.json")"; rc=$?
[[ $rc -eq 0 && "$out" == *warning* ]] && ok "L4 an unreadable installed_plugins.json warns instead of aborting" || bad "L4 broken" "rc=$rc $out"
grep -q 'scripts/check-plugin-ids.py" "$REPO_DIR/settings.json" "$installed_plugins" "$CLAUDE_DIR/settings.json"' "$ROOT/setup.sh" \
  && ok "L4 setup.sh runs scripts/check-plugin-ids.py against the live settings.json" || bad "L4 wiring" "setup.sh does not call the check with the live file"

# --- L2 / L4 live: the installed enforcer -------------------------------------
PLUGIN_ROOT="$(ls -d "$HOME"/.claude/plugins/cache/claude-code-harness-marketplace/harness/*/ 2>/dev/null | sort -V | tail -1)"
BIN="${PLUGIN_ROOT%/}/bin/harness"
if [[ -z "$PLUGIN_ROOT" || ! -x "$BIN" ]]; then
  skp "L2 harness plugin not installed on this machine"
  skp "L4 live: harness plugin not installed on this machine"
else
  PROJ="$SB/proj"
  mkdir -p "$PROJ/.git"
  PROPOSED="$(python3 -c 'import json,sys;print(",".join(a["pattern"] for a in json.load(open(sys.argv[1]))["secret_read"]["proposed_allow"]))' "$DECL")"

  decide() { # $1 = allow env ("" = unset), $2 = command → prints the deny reason or ""
    python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"cwd":sys.argv[1],"session_id":"floor-allowlist-test"}))' "$PROJ" "$2" \
      | if [[ -n "$1" ]]; then HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="$1" "$BIN" hook pre-tool; else env -u HARNESS_RUNTIME_FLOOR_SECRET_ALLOW "$BIN" hook pre-tool; fi 2>/dev/null \
      | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
o=json.loads(raw) if raw else {}
h=o.get("hookSpecificOutput",{})
print(h.get("permissionDecisionReason","") if h.get("permissionDecision")=="deny" else "")'
  }
  list() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print("\n".join(d))' "$DECL" "$1"; }

  while IFS= read -r cmd; do
    r0="$(decide "" "$cmd")"; r1="$(decide "$PROPOSED" "$cmd")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* && "$r1" == RUNTIME_FLOOR:secret-read* ]] \
      && ok "L2 denied now and with the proposed env: $cmd" || bad "L2 must_deny" "$cmd -> now='$r0' proposed='$r1'"
  done < <(list secret_read.must_deny)

  while IFS= read -r cmd; do
    r0="$(decide "" "$cmd")"; r1="$(decide "$PROPOSED" "$cmd")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* && -z "$r1" ]] \
      && ok "L2 false positive recorded (denied now, allowed by the proposal): $cmd" || bad "L2 observed_false_positives" "$cmd -> now='$r0' proposed='$r1'"
  done < <(list secret_read.observed_false_positives)

  while IFS= read -r cmd; do
    r0="$(decide "" "$cmd")"; r1="$(decide "$PROPOSED" "$cmd")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* && -z "$r1" ]] \
      && ok "L2 why not enforced: the proposal would open $cmd" \
      || bad "L2 composition_opened_by_proposal changed (upstream tokenizer fixed?) — re-evaluate enforced" "$cmd -> now='$r0' proposed='$r1'"
  done < <(list secret_read.composition_opened_by_proposal)

  while IFS= read -r cmd; do
    r="$(decide "$PROPOSED" "$cmd")"
    [[ "$r" == RUNTIME_FLOOR:secret-read* ]] && ok "L2 known upstream limit (bare name) denied even with the proposal: $cmd" \
      || bad "L2 known_upstream_limits changed" "$cmd -> '${r}'"
  done < <(list secret_read.known_upstream_limits.still_denied)

  while IFS= read -r cmd; do
    r="$(decide "" "$cmd")"
    [[ "$r" == RUNTIME_FLOOR:egress* ]] && ok "L2 external egress denied: $cmd" || bad "L2 external egress allowed" "$cmd -> '${r}'"
  done < <(list egress.must_deny_external)

  if grep -q "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["egress"]["proposed_env"])' "$DECL")" \
      "${PLUGIN_ROOT%/}/go/internal/runtimefloor/runtimefloor.go" 2>/dev/null; then
    bad "L3 the installed plugin now reads the proposed egress env" "re-evaluate egress.enforced"
  else
    ok "L3 the installed plugin has no egress allowlist knob (egress.enforced=false is accurate)"
  fi

  INSTALLED="$HOME/.claude/plugins/installed_plugins.json"
  if [[ -f "$INSTALLED" ]]; then
    l4="$(python3 "$C" "$SETTINGS" "$INSTALLED" "$HOME/.claude/settings.json" 2>&1)"; l4rc=$?
    [[ $l4rc -eq 0 ]] && ok "L4 live: this settings.json turns off no installed plugin by drift" || bad "L4 live" "$l4"
  else
    skp "L4 live: installed_plugins.json not present"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
