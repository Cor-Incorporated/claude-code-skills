#!/usr/bin/env bash
# 宣言 (config/runtime-floor-allowlist.json) ↔ 配備値 (settings.json env) ↔
# 強制 (harness plugin の bin/harness hook pre-tool) を機械的に結ぶ。
#
# 起点 (2026-10-30 harness-pdca F1/F2): 値の無い雛形 smb-credentials.cred.template の
# cat が RUNTIME_FLOOR:secret-read で止まった。許可は plugin の
# HARNESS_RUNTIME_FLOOR_SECRET_ALLOW でしか表せないが、実 enforcer に当てると
# 許可した名前に秘密を空白なしで連結した形 (cat ~/.aws/credentials;x.template) まで
# 通ることが分かった (#446 review)。だから secret_read は今も enforced=false。
#
# egress (2026-10-31, aidd-governance#230 / ADR-014): 5.16.0 の egress 床は誤検知率
# 75 % で退役条件に当たり、Cor の private mirror (5.16.0-cor.1) で再設計した。
# クラスタは HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW、読み取りだけ通す公開レジストリは
# HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW で宣言し、settings.json が配る。
#
# 層:
#   L1 enforced=false の区分は settings.json に env を置かない (宣言だけで効いた
#      ことにしない)。enforced=true なら値が一字一句一致する。両方の値を挙げて落ちる
#   L2 実 enforcer: 現在 (env なし) の判定と、宣言した env での判定を両方記録する。
#      secret_read: must_deny は両方で deny、observed_false_positives は env なしで
#      deny / env ありで allow。composition_opened_by_proposal は、composition_fixed_in
#      より前の enforcer では env ありで allow (= enforced にしない理由)、以後は deny
#   L3 egress: enforcer が requires_enforcer なら incident_inputs の after・must_allow・
#      must_deny を宣言どおりの env で確かめ、env を外す片側変異で red になることも
#      確かめる。それより前の enforcer (5.16.0) では incident_inputs の before が再現する
#      ことだけ確かめ、after は「切り替え待ち (人間ゲート)」として SKIP に数える
#   L4 settings.json の enabledPlugins ↔ インストール済み plugin ↔ live の settings.json
#      (2026-10-30 実測: repo は claude-code-harness@…、実体は harness@…。この
#       settings.json を setup.sh で配ると床ごと plugin が無効になる)
#
# 実 enforcer は既定でインストール済み plugin の bin/harness。HARNESS_FLOOR_BIN で
# 別の build (mirror の bin/harness-darwin-arm64 など) を指せる。
# L2/L3 と live 側の L4 は plugin がある機械だけで走る (CI では SKIP と数える)。
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

# --- L1: declaration ↔ settings.json -----------------------------------------
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
for part in ("internal", "read"):
    k = eg[part]["env"]
    declared = ",".join(eg[part]["entries"])
    if eg["enforced"] and env.get(k) != declared:
        problems.append(f"egress.{part}: declared={declared!r} settings.json={env.get(k)!r}")
    if not eg["enforced"] and k in env:
        problems.append(f"egress.enforced=false but settings.json sets {k}")
print("; ".join(problems))
PY
}
out="$(decl_check "$SETTINGS")"
[[ -z "$out" ]] && ok "L1 settings.json carries exactly the floor env the declaration enforces" || bad "L1" "$out"

mutate_settings() { # $1 = python expression on s["env"] → writes $SB/settings-mutant.json
  python3 - "$SETTINGS" "$SB/settings-mutant.json" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
env = s["env"]
exec(sys.argv[3])
json.dump(s, open(sys.argv[2], "w"))
PY
}
mutate_settings 'env["HARNESS_RUNTIME_FLOOR_SECRET_ALLOW"] = "*.template"'
out="$(decl_check "$SB/settings-mutant.json")"
[[ -n "$out" ]] && ok "L1 one-sided mutation (secret env added to settings.json only) goes red: $out" || bad "L1 mutation secret" "not detected"
mutate_settings 'env["HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW"] = env["HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW"].rsplit(",", 1)[0]'
out="$(decl_check "$SB/settings-mutant.json")"
[[ "$out" == *"declared="*"settings.json="* ]] && ok "L1 one-sided mutation (a cluster host dropped from settings.json only) goes red with both values" || bad "L1 mutation egress" "${out:-not detected}"
mutate_settings 'env["HARNESS_RUNTIME_FLOOR_EGRESS"] = "off"'
out="$(decl_check "$SB/settings-mutant.json")"
[[ "$out" == *"EGRESS=off"* ]] && ok "L1 HARNESS_RUNTIME_FLOOR_EGRESS=off in settings.json goes red" || bad "L1 mutation off" "${out:-not detected}"

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

# --- L2 / L3 / L4 live: the enforcer ------------------------------------------
# The installed plugin is the one installed_plugins.json records, not the highest cache directory:
# after a switch both 5.16.0/ and 5.16.0-cor.1/ stay, and `sort -V` puts "5.16.0/" last (#456 review).
PLUGIN_ROOT="$(python3 -c 'import json,os,sys
try:
    d = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
    print(d["plugins"]["harness@claude-code-harness-marketplace"][0]["installPath"])
except Exception:
    sys.exit(0)' 2>/dev/null)"
BIN="${HARNESS_FLOOR_BIN:-${PLUGIN_ROOT%/}/bin/harness}"
if [[ -n "${HARNESS_FLOOR_BIN:-}" && ! -x "$BIN" ]]; then
  # A mistyped override must not turn L2/L3/L4 into SKIPs and a green run (#456 review round 2).
  bad "HARNESS_FLOOR_BIN" "HARNESS_FLOOR_BIN=$BIN is not an executable file"
elif [[ ! -x "$BIN" ]]; then
  skp "L2 harness enforcer not installed on this machine"
  skp "L3 harness enforcer not installed on this machine"
  skp "L4 live: harness plugin not installed on this machine"
else
  VERSION="$("$BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)"
  [[ -n "$VERSION" ]] || VERSION="$(basename "${PLUGIN_ROOT%/}")"
  echo "enforcer: $BIN (version ${VERSION:-unknown})"
  PROJ="$SB/proj"
  mkdir -p "$PROJ/.git"
  jq_decl() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print(d if isinstance(d,str) else "\n".join(d) if isinstance(d,list) and all(isinstance(x,str) for x in d) else json.dumps(d))' "$DECL" "$1"; }
  PROPOSED="$(python3 -c 'import json,sys;print(",".join(a["pattern"] for a in json.load(open(sys.argv[1]))["secret_read"]["proposed_allow"]))' "$DECL")"
  EG_INTERNAL="$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["egress"]["internal"]["entries"]))' "$DECL")"
  EG_READ="$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["egress"]["read"]["entries"]))' "$DECL")"

  # decide <command> [VAR=value ...] → prints the deny reason or "". Every floor
  # variable of the calling shell is removed first, so only the given ones apply.
  decide() {
    local cmd="$1"; shift
    python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"cwd":sys.argv[1],"session_id":"floor-allowlist-test"}))' "$PROJ" "$cmd" \
      | env -u HARNESS_RUNTIME_FLOOR_SECRET_ALLOW -u HARNESS_RUNTIME_FLOOR_EGRESS -u HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW \
          -u HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW "$@" "$BIN" hook pre-tool 2>/dev/null \
      | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
o=json.loads(raw) if raw else {}
h=o.get("hookSpecificOutput",{})
print(h.get("permissionDecisionReason","") if h.get("permissionDecision")=="deny" else "")'
  }
  SECRET_ENV="HARNESS_RUNTIME_FLOOR_SECRET_ALLOW=$PROPOSED"
  EGRESS_ENV=("HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW=$EG_INTERNAL" "HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW=$EG_READ")

  # L2 secret_read
  while IFS= read -r cmd; do
    r0="$(decide "$cmd")"; r1="$(decide "$cmd" "$SECRET_ENV")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* && "$r1" == RUNTIME_FLOOR:secret-read* ]] \
      && ok "L2 denied now and with the proposed env: $cmd" || bad "L2 must_deny" "$cmd -> now='$r0' proposed='$r1'"
  done < <(jq_decl secret_read.must_deny)

  while IFS= read -r cmd; do
    r0="$(decide "$cmd")"; r1="$(decide "$cmd" "$SECRET_ENV")"
    [[ "$r0" == RUNTIME_FLOOR:secret-read* && -z "$r1" ]] \
      && ok "L2 false positive recorded (denied now, allowed by the proposal): $cmd" || bad "L2 observed_false_positives" "$cmd -> now='$r0' proposed='$r1'"
  done < <(jq_decl secret_read.observed_false_positives)

  FIXED_IN="$(jq_decl secret_read.composition_fixed_in)"
  while IFS= read -r cmd; do
    r0="$(decide "$cmd")"; r1="$(decide "$cmd" "$SECRET_ENV")"
    if [[ "$VERSION" == "$FIXED_IN" ]]; then
      [[ "$r0" == RUNTIME_FLOOR:secret-read* && "$r1" == RUNTIME_FLOOR:secret-read* ]] \
        && ok "L2 composition closed in $FIXED_IN (denied with the proposal): $cmd" \
        || bad "L2 composition_fixed_in $FIXED_IN does not close" "$cmd -> now='$r0' proposed='$r1'"
    else
      [[ "$r0" == RUNTIME_FLOOR:secret-read* && -z "$r1" ]] \
        && ok "L2 why not enforced: the proposal would open $cmd" \
        || bad "L2 composition_opened_by_proposal changed (tokenizer fixed?) — re-evaluate enforced" "$cmd -> now='$r0' proposed='$r1'"
    fi
  done < <(jq_decl secret_read.composition_opened_by_proposal)

  while IFS= read -r cmd; do
    r="$(decide "$cmd" "$SECRET_ENV")"
    [[ "$r" == RUNTIME_FLOOR:secret-read* ]] && ok "L2 known upstream limit (bare name) denied even with the proposal: $cmd" \
      || bad "L2 known_upstream_limits changed" "$cmd -> '${r}'"
  done < <(jq_decl secret_read.known_upstream_limits.still_denied)

  # L3 egress
  REQUIRES="$(jq_decl egress.requires_enforcer)"
  incidents() { python3 -c 'import json,sys
for r in json.load(open(sys.argv[1]))["egress"]["incident_inputs"]: print(r["id"]+"\t"+r[sys.argv[2]]+"\t"+r["cmd"])' "$DECL" "$1"; }
  if [[ "$VERSION" == "$REQUIRES" ]]; then
    while IFS=$'\t' read -r id want cmd; do
      r="$(decide "$cmd" "${EGRESS_ENV[@]}")"
      got=allow; [[ -n "$r" ]] && got=deny
      [[ "$got" == "$want" ]] && ok "L3 $id after=$want with the declared env: $cmd" || bad "L3 incident $id" "want $want, got $got ($r): $cmd"
    done < <(incidents after)
    while IFS= read -r cmd; do
      r="$(decide "$cmd" "${EGRESS_ENV[@]}")"
      [[ -z "$r" ]] && ok "L3 must_allow: $cmd" || bad "L3 must_allow denied" "$cmd -> '$r'"
    done < <(jq_decl egress.must_allow)
    while IFS= read -r cmd; do
      r="$(decide "$cmd" "${EGRESS_ENV[@]}")"
      [[ "$r" == RUNTIME_FLOOR:egress* ]] && ok "L3 must_deny: $cmd" || bad "L3 must_deny allowed" "$cmd -> '${r}'"
    done < <(jq_decl egress.must_deny)
    # One-sided mutation on the enforcer side: without the env, cluster and
    # registry reads are denied again, so it is the declaration that opens them.
    for id in F2-5 F2-8; do
      cmd="$(incidents after | awk -F'\t' -v id="$id" '$1==id {print $3}')"
      r="$(decide "$cmd")"
      [[ "$r" == RUNTIME_FLOOR:egress* ]] && ok "L3 mutation: $id denied once the declared env is removed" || bad "L3 mutation $id" "allowed without the env: $cmd"
    done
    # The binary that ran must contain both variable names (bin/harness may be the shell shim, so
    # its platform binaries next to it are read too).
    reads=0
    for f in "$BIN" "${BIN%/*}"/harness-*; do
      [[ -f "$f" ]] && grep -aq HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW "$f" && grep -aq HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW "$f" && reads=1 && break
    done
    [[ $reads -eq 1 ]] && ok "L3 the enforcer binary reads both declared egress variables" \
      || bad "L3 binary" "neither $BIN nor its platform binaries name HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW and _READ_ALLOW"
    # egress.requires_commit ↔ the enforcer: a Go change pushed to `cor` without a VERSION bump would
    # install as the same version with other code (#456 review round 2).
    PIN="$(jq_decl egress.requires_commit)"
    if [[ -z "${HARNESS_FLOOR_BIN:-}" ]]; then
      SHA="$(python3 -c 'import json,os
d = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
print(d["plugins"]["harness@claude-code-harness-marketplace"][0].get("gitCommitSha", ""))' 2>/dev/null)"
      [[ "$SHA" == "$PIN" ]] && ok "L3 installed commit is egress.requires_commit ($PIN)" \
        || bad "L3 requires_commit" "declared=$PIN installed gitCommitSha=${SHA:-none}"
    else
      # An override build is checked binary by binary against the pinned commit of its own checkout.
      TOP="$(git -C "${BIN%/*}" rev-parse --show-toplevel 2>/dev/null)"
      if [[ -n "$TOP" ]] && git -C "$TOP" cat-file -e "$PIN^{commit}" 2>/dev/null; then
        diffs=""
        for f in "${BIN%/*}"/harness-*; do
          [[ -f "$f" ]] || continue
          git -C "$TOP" show "$PIN:bin/${f##*/}" 2>/dev/null | cmp -s - "$f" || diffs="$diffs ${f##*/}"
        done
        [[ -z "$diffs" ]] && ok "L3 override binaries equal those at egress.requires_commit ($PIN)" \
          || bad "L3 requires_commit" "declared=$PIN; these binaries differ from that commit:$diffs"
      else
        skp "L3 requires_commit: $PIN is not in the override's checkout (${TOP:-not a git checkout})"
      fi
    fi
  else
    while IFS=$'\t' read -r id want cmd; do
      r="$(decide "$cmd" "${EGRESS_ENV[@]}")"
      got=allow; [[ -n "$r" ]] && got=deny
      [[ "$got" == "$want" ]] && ok "L3 $id before=$want reproduces on $VERSION: $cmd" || bad "L3 incident $id before" "want $want, got $got ($r): $cmd"
    done < <(incidents before)
    skp "L3 egress after/must_allow/must_deny need enforcer $REQUIRES (this one is ${VERSION:-unknown}); switch per docs/runbooks/harness-cor-mirror.md (human gate) or run with HARNESS_FLOOR_BIN"
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
