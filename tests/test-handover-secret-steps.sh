#!/usr/bin/env bash
# Link test (2026-10-31 secret-registration incident, claude-code-skills#473): handover and runbook steps never store a
# secret except through the verify-first script, and the rule's declarations point at that script and reach every
# agent.
#
#   S1 a line with `gh secret set` passes only when the same line names register-secret-verified, or carries (or
#      follows a line carrying) an explicit `<!-- secret-set-ok: <reason> -->`. A nearby word "verify" is not enough:
#      the incident's own one-liner (`curl …/tokens/verify; gh secret set …`) had it. Scanned: docs/, skills/,
#      rules/, README.md, AGENTS.md, hooks/lib/aidd_cc_contract.md, and every directory in AIDD_HANDOVER_DIRS
#      (colon-separated; e.g. the desktop-handoffs folders, which are outside the repository).
#   S2 skills/handover/common-clauses.md and rules/runbook.md name register-secret-verified.sh; the contract text that
#      hooks/lib/aidd_cc_contract.py delivers to each of codex / cursor / pi / dsh / opencode names it; and the script
#      exists with its verify gate.
#   S3 self-test: the incident one-liner, a check-less line, a `## 検証` heading nearby and prose saying verify is not
#      needed are all red; the script line and a marked line are green.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

# scan <dir|file>... → prints file:line for each `gh secret set` that does not go through the script
scan() {
  python3 -I - "$@" <<'PY'
import os, re, sys
SET = re.compile(r"\bgh\s+secret\s+set\b")
VIA = re.compile(r"register-secret-verified")
MARK = re.compile(r"<!--\s*secret-set-ok:\s*\S")
EXT = (".md", ".sh", ".txt", ".yaml", ".yml", ".json")
paths = []
for a in sys.argv[1:]:
    if os.path.isfile(a):
        paths.append(a)
    elif os.path.isdir(a):
        for d, subs, files in os.walk(a):
            subs[:] = [s for s in subs if s not in (".git", "_unused", "node_modules")]
            paths += [os.path.join(d, f) for f in files if f.endswith(EXT)]
for p in sorted(paths):
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        if not SET.search(line):
            continue
        if VIA.search(line) or MARK.search(line) or (i > 0 and MARK.search(lines[i - 1])):
            continue
        print("%s:%d: %s" % (p, i + 1, line.strip()[:120]))
PY
}

targets=("$ROOT/docs" "$ROOT/skills" "$ROOT/rules" "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT/hooks/lib/aidd_cc_contract.md")
IFS=':' read -r -a extra <<<"${AIDD_HANDOVER_DIRS:-}"
for d in "${extra[@]}"; do [[ -n "$d" && -e "$d" ]] && targets+=("$d"); done
found="$(scan "${targets[@]}")"
[[ -z "$found" ]] && ok "S1 no gh secret set outside register-secret-verified.sh in ${#targets[@]} scanned places" \
  || bad "S1 gh secret set not through the script (use register-secret-verified.sh, or mark the line with a reason)" "$found"

missing=""
for f in skills/handover/common-clauses.md rules/runbook.md; do
  grep -q 'register-secret-verified.sh' "$ROOT/$f" || missing="$missing $f"
done
for a in codex cursor pi dsh opencode; do
  python3 -I "$ROOT/hooks/lib/aidd_cc_contract.py" text --agent "$a" 2>/dev/null | grep -q 'register-secret-verified.sh' \
    || missing="$missing contract($a)"
done
[[ -z "$missing" ]] && ok "S2 the runbook, the common clauses and the contract delivered to all five agents name the script" \
  || bad "S2 declarations" "missing in:$missing"
S="$ROOT/scripts/register-secret-verified.sh"
[[ -f "$S" ]] && grep -q 'if \[\[ -z "\$ok" \]\]; then' "$S" && grep -q 'no --verify-url' "$S" \
  && ok "S2 the enforcing script exists and has its verify gate and its no-verify refusal" \
  || bad "S2 script" "$S missing or without the gate"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
printf '1. run:\n\n    curl -s https://api.example/tokens/verify; gh secret set TOKEN --repo o/r < t\n' >"$SB/incident.md"
printf '1. run:\n\n    gh secret set TOKEN --repo o/r < token.txt\n' >"$SB/bare.md"
printf '## 検証\n\nnotes\n\n    gh secret set TOKEN --repo o/r < t\n' >"$SB/heading.md"
printf 'verify は不要です。\n    gh secret set TOKEN --repo o/r < t\n' >"$SB/prose.md"
printf '    bash ~/.claude/scripts/register-secret-verified.sh TOKEN o/r --cloudflare-account x  # wraps gh secret set\n' >"$SB/script.md"
printf '<!-- secret-set-ok: a generated value, no provider to verify -->\n    openssl rand -hex 32 | gh secret set SALT --repo o/r\n' >"$SB/marked.md"
reds=""; for f in incident bare heading prose; do [[ -n "$(scan "$SB/$f.md")" ]] || reds="$reds $f"; done
greens=""; for f in script marked; do [[ -z "$(scan "$SB/$f.md")" ]] || greens="$greens $f"; done
[[ -z "$reds" && -z "$greens" ]] && ok "S3 the incident one-liner, a bare line, a nearby 検証 heading and 'verify は不要' are red; the script and a marked line are green" \
  || bad "S3 self-test" "not red:${reds:- none}; not green:${greens:- none}"

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
