#!/usr/bin/env bash
# skills/handover/validate-lane-manifest.py の検査。
#
# 起点 (2026-10-29): 7 本の依頼に「レーン → repo パス」が無く、3 レーンが編集 0 で停止。
# 台帳が「撃てる」ことを、実際の git repo と bare origin で確かめる。
#
# 反証可能性: 正しい台帳から 1 点だけ壊した写し 6 本が、それぞれ該当する理由で red になる。
# 標準枠は SKILL.md の表と台帳の両側から 1 件落として red を見る (宣言 ↔ 検証器のリンク)。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/skills/handover/validate-lane-manifest.py"
SKILL="$ROOT/skills/handover/SKILL.md"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

git init -q --bare "$SB/origin.git"
git init -q -b develop "$SB/repo"
git -C "$SB/repo" config user.email t@example.invalid
git -C "$SB/repo" config user.name t
git -C "$SB/repo" commit -q --allow-empty -m init
git -C "$SB/repo" remote add origin "$SB/origin.git"
git -C "$SB/repo" push -q origin develop
git -C "$SB/repo" fetch -q origin
mkdir -p "$SB/reports"

IDS="$(python3 -c 'import json,re,sys;print(json.dumps(sorted(set(re.findall(r"^\|\s*(HP-\d+)\s*\|",open(sys.argv[1]).read(),re.M)))))' "$SKILL")"

write_manifest() { # $1 = out path, $2 = python expression applied to manifest m
  python3 - "$1" "$SB" "$IDS" "$2" <<'PY'
import json, sys
out, sb, ids, mutate = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
lane = lambda topic, slug, owns: {
    "topic": topic, "cwd": f"{sb}/repo", "origin": f"{sb}/origin.git", "base": "develop",
    "worktree": f"{sb}/repo/.worktrees/claude/{slug}", "branch": f"feat/{slug}",
    "commit_allowed": True, "report_to": f"{sb}/reports/{topic}.md", "owns": owns,
}
m = {"schema": "lane-manifest.v1", "standard_prohibitions": ids,
     "lanes": [lane("a", "lane-a", ["src/a/"]), lane("b", "lane-b", ["src/b/"])]}
exec(mutate)
json.dump(m, open(out, "w"))
PY
}

run() { python3 "$V" "$1" "${2:-$SKILL}" 2>&1; }

write_manifest "$SB/good.json" "pass"
out="$(run "$SB/good.json")"; rc=$?
[[ $rc -eq 0 ]] && ok "a complete 2-lane manifest validates: $out" || bad "good manifest" "$out"

case_red() { # $1 = name, $2 = mutation, $3 = expected substring
  write_manifest "$SB/m.json" "$2"
  local out rc
  out="$(run "$SB/m.json")"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"$3"* ]]; then ok "$1 → red ($3)"; else bad "$1" "rc=$rc out=$out"; fi
}

case_red "cwd is not a repo" 'm["lanes"][0]["cwd"]=sb+"/nope"' "is not a git repository"
case_red "origin mismatch" 'm["lanes"][0]["origin"]="git@github.com:x/other.git"' "origin declared"
case_red "base missing on origin" 'm["lanes"][1]["base"]="release"' "base origin/release not found"
case_red "worktree outside <cwd>/.worktrees" 'm["lanes"][0]["worktree"]=sb+"/repo-lane-a"' "is not <cwd>/.worktrees"
case_red "two lanes share a worktree" 'm["lanes"][1]["worktree"]=m["lanes"][0]["worktree"]' "is also used by"
case_red "overlapping ownership" 'm["lanes"][1]["owns"]=["src/a/sub/"]' "in the same repo"
case_red "worktree none but commits allowed" 'm["lanes"][0]["worktree"]="none"' "requires commit_allowed: false"
case_red "missing report dir" 'm["lanes"][0]["report_to"]=sb+"/no-such-dir/r.md"' "report_to directory"
case_red "a standard prohibition dropped from the manifest" 'm["standard_prohibitions"]=m["standard_prohibitions"][:-1]' "standard_prohibitions: missing"

write_manifest "$SB/none.json" 'm["lanes"][0]["worktree"]="none"; m["lanes"][0]["commit_allowed"]=False'
out="$(run "$SB/none.json")"; rc=$?
[[ $rc -eq 0 ]] && ok "worktree none + commit_allowed false is a valid commit-0 lane" || bad "commit-0 lane" "$out"

# 宣言側の片側変異: SKILL.md の表に HP 行を 1 本足すと、既存の台帳が red になる
sed 's/^| HP-6 |/| HP-7 | test row | x |\n| HP-6 |/' "$SKILL" >"$SB/SKILL-plus.md"
grep -q '^| HP-7 |' "$SB/SKILL-plus.md" || printf '| HP-7 | test row | x |\n' >>"$SB/SKILL-plus.md"
out="$(run "$SB/good.json" "$SB/SKILL-plus.md")"; rc=$?
[[ $rc -ne 0 && "$out" == *"HP-7"* ]] && ok "a new HP row in SKILL.md turns an old manifest red" || bad "SKILL.md side mutation" "rc=$rc out=$out"

python3 -c 'import yaml' 2>/dev/null && {
  out="$(python3 "$V" "$ROOT/skills/handover/lane-manifest.template.yaml" 2>&1)"
  [[ "$out" == *"standard_prohibitions: missing"* ]] && bad "template carries every HP id" "$out" || ok "the template carries every HP id in SKILL.md"
}

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
