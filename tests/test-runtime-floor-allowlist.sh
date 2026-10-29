#!/usr/bin/env bash
# 宣言 (config/runtime-floor-allowlist.json) ↔ 配備値 (settings.json env) ↔
# 強制 (harness plugin の bin/harness hook pre-tool) を機械的に結ぶ。
#
# 起点 (2026-10-30 harness-pdca F1/F2): 値の無い雛形 smb-credentials.cred.template の
# cat が RUNTIME_FLOOR:secret-read で止まった。許可は plugin の
# HARNESS_RUNTIME_FLOOR_SECRET_ALLOW でしか表せない。宣言だけ増やして配備値を
# 変え忘れる・配備値だけ変えて宣言を変え忘れる、のどちらでも落ちること。
#
# 3 層:
#   L1 宣言と settings.json の値が一字一句一致する (両方の値を挙げて落ちる)
#   L2 実際の enforcer に must_allow / must_deny を流し、宣言通りに判定される。
#      must_allow は「env なしだと deny」も確かめる (allowlist が効いている証拠)
#   L3 egress は enforced=false。plugin に knob が無いので、配備値に
#      HARNESS_RUNTIME_FLOOR_EGRESS=off や提案中の env を置いていないこと
#   L4 settings.json の enabledPlugins が実際にインストールされた plugin id と一致する
#      (2026-10-30 実測: repo は claude-code-harness@…、実体は harness@…。この
#       settings.json を setup.sh で配ると床ごと plugin が無効になる)
#
# L2 と L4 は plugin がインストールされた機械だけで走る (CI では SKIP と数える)。
#
# 片側変異: L1 は settings の値から 1 件落とした写しで red、L2 は env を外して red
# になることをこの中で実測する。
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

# --- L1 ---------------------------------------------------------------------
l1_check() { # $1 = settings path → prints "" on match, or the diff
  python3 - "$DECL" "$1" <<'PY'
import json, sys
decl = json.load(open(sys.argv[1]))
settings = json.load(open(sys.argv[2]))
env = decl["secret_read"]["env"]
want = ",".join(a["pattern"] for a in decl["secret_read"]["allow"])
have = settings.get("env", {}).get(env)
if have != want:
    print(f"declared={want!r} settings.json={have!r}")
PY
}
diff_l1="$(l1_check "$SETTINGS")"
[[ -z "$diff_l1" ]] && ok "L1 settings.json env matches the declaration" || bad "L1 declaration ↔ settings.json" "$diff_l1"

python3 - "$SETTINGS" "$SB/settings-mutant.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
key = "HARNESS_RUNTIME_FLOOR_SECRET_ALLOW"
s["env"][key] = ",".join(s["env"].get(key, "").split(",")[:-1])
json.dump(s, open(sys.argv[2], "w"))
PY
mut_l1="$(l1_check "$SB/settings-mutant.json")"
[[ -n "$mut_l1" ]] && ok "L1 one-sided mutation goes red: $mut_l1" || bad "L1 mutation" "dropping a pattern from settings.json was not detected"

# --- L3 ---------------------------------------------------------------------
l3="$(python3 - "$DECL" "$SETTINGS" <<'PY'
import json, sys
decl = json.load(open(sys.argv[1]))
env = json.load(open(sys.argv[2])).get("env", {})
eg = decl["egress"]
problems = []
if str(env.get("HARNESS_RUNTIME_FLOOR_EGRESS", "")).strip().lower() == "off":
    problems.append("settings.json sets HARNESS_RUNTIME_FLOOR_EGRESS=off (disables the whole category)")
if not eg["enforced"] and eg["proposed_env"] in env:
    problems.append(f"{eg['proposed_env']} is in settings.json but egress.enforced=false (declared, not enforced)")
print("; ".join(problems))
PY
)"
[[ -z "$l3" ]] && ok "L3 egress stays enforced by the plugin; no blanket off, no pretend allowlist" || bad "L3 egress" "$l3"

# --- L2 / L4: the installed enforcer ------------------------------------------
PLUGIN_ROOT="$(ls -d "$HOME"/.claude/plugins/cache/claude-code-harness-marketplace/harness/*/ 2>/dev/null | sort -V | tail -1)"
BIN="${PLUGIN_ROOT%/}/bin/harness"
if [[ -z "$PLUGIN_ROOT" || ! -x "$BIN" ]]; then
  skp "L2 harness plugin not installed on this machine"
  skp "L4 harness plugin not installed on this machine"
else
  PROJ="$SB/proj"
  mkdir -p "$PROJ/.git"
  ALLOW="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["env"]["HARNESS_RUNTIME_FLOOR_SECRET_ALLOW"])' "$SETTINGS")"

  decide() { # $1 = allow env ("" = unset), $2 = command → prints deny reason or ""
    python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"cwd":sys.argv[1],"session_id":"floor-allowlist-test"}))' "$PROJ" "$2" \
      | if [[ -n "$1" ]]; then HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="$1" "$BIN" hook pre-tool; else env -u HARNESS_RUNTIME_FLOOR_SECRET_ALLOW "$BIN" hook pre-tool; fi 2>/dev/null \
      | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
o=json.loads(raw) if raw else {}
h=o.get("hookSpecificOutput",{})
print(h.get("permissionDecisionReason","") if h.get("permissionDecision")=="deny" else "")'
  }

  while IFS= read -r cmd; do
    r="$(decide "$ALLOW" "$cmd")"
    [[ -z "$r" ]] && ok "L2 allowed with the declared env: $cmd" || bad "L2 must_allow denied" "$cmd → $r"
    r0="$(decide "" "$cmd")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* ]] && ok "L2 mutation (no env) denies it: $cmd" \
      || bad "L2 must_allow is allowed even without the env (allowlist proves nothing)" "$cmd → '${r0}'"
  done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["secret_read"]["must_allow"]))' "$DECL")

  while IFS= read -r cmd; do
    r="$(decide "$ALLOW" "$cmd")"
    [[ "$r" == RUNTIME_FLOOR:secret-read* ]] && ok "L2 still denied with the declared env: $cmd" || bad "L2 must_deny allowed" "$cmd → '${r}'"
  done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["secret_read"]["must_deny"]))' "$DECL")

  while IFS= read -r cmd; do
    r="$(decide "$ALLOW" "$cmd")"
    [[ "$r" == RUNTIME_FLOOR:egress* ]] && ok "L2 external egress still denied: $cmd" || bad "L2 external egress allowed" "$cmd → '${r}'"
  done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["egress"]["must_deny_external"]))' "$DECL")

  if grep -q "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["egress"]["proposed_env"])' "$DECL")" \
      "${PLUGIN_ROOT%/}/go/internal/runtimefloor/runtimefloor.go" 2>/dev/null; then
    bad "L3 the installed plugin now reads the proposed egress env" "flip egress.enforced to true and render it into settings.json"
  else
    ok "L3 the installed plugin has no egress allowlist knob (egress.enforced=false is accurate)"
  fi

  INSTALLED="$HOME/.claude/plugins/installed_plugins.json"
  if [[ -f "$INSTALLED" ]]; then
    l4="$(python3 - "$SETTINGS" "$INSTALLED" <<'PY'
import json, sys
enabled = [k for k, v in json.load(open(sys.argv[1])).get("enabledPlugins", {}).items() if v]
installed = set(json.load(open(sys.argv[2])).get("plugins", {}))
missing = [k for k in enabled if k not in installed]
if missing:
    near = sorted(i for i in installed if any(m.split("@")[-1] == i.split("@")[-1] for m in missing))
    print(f"enabled in settings.json but not installed: {missing}; installed from the same marketplace: {near}")
PY
)"
    [[ -z "$l4" ]] && ok "L4 every enabledPlugins id in settings.json is installed" || bad "L4 settings.json ↔ installed plugins" "$l4"
  else
    skp "L4 installed_plugins.json not present"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
