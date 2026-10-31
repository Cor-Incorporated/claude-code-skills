#!/usr/bin/env bash
# Link test (2026-10-31 secret-registration incident): handover and runbook steps never store a secret without a
# check, and the rule's three declarations point at the script that enforces it.
#
#   S1 every line with `gh secret set` has `verify`, `検証` or `register-secret-verified` on it or in the 5 lines
#      before it. Scanned: docs/, skills/, rules/, hooks/lib/aidd_cc_contract.md, and every directory in
#      AIDD_HANDOVER_DIRS (colon-separated; e.g. the desktop-handoffs folders, which are outside the repository).
#   S2 skills/handover/common-clauses.md, rules/runbook.md and hooks/lib/aidd_cc_contract.md name
#      register-secret-verified.sh, and that script exists and has the verify gate.
#   S3 self-test: a fixture with a bare `gh secret set` goes red naming file:line; with a verify line before it, green.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

# scan <dir|file>... → prints file:line for each unverified `gh secret set`
scan() {
  python3 - "$@" <<'PY'
import os, re, sys
SET = re.compile(r"\bgh\s+secret\s+set\b")
OK = re.compile(r"verify|検証|register-secret-verified", re.IGNORECASE)
paths = []
for a in sys.argv[1:]:
    if os.path.isfile(a):
        paths.append(a)
    elif os.path.isdir(a):
        for d, _subs, files in os.walk(a):
            if "/.git" in d or "/_unused" in d:
                continue
            paths += [os.path.join(d, f) for f in files if f.endswith((".md", ".sh", ".txt", ".yaml", ".yml"))]
for p in sorted(paths):
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        if SET.search(line) and not any(OK.search(l) for l in lines[max(0, i - 5):i + 1]):
            print("%s:%d: %s" % (p, i + 1, line.strip()[:120]))
PY
}

targets=("$ROOT/docs" "$ROOT/skills" "$ROOT/rules" "$ROOT/hooks/lib/aidd_cc_contract.md")
IFS=':' read -r -a extra <<<"${AIDD_HANDOVER_DIRS:-}"
for d in "${extra[@]}"; do [[ -n "$d" && -e "$d" ]] && targets+=("$d"); done
found="$(scan "${targets[@]}")"
[[ -z "$found" ]] && ok "S1 no unverified gh secret set in ${#targets[@]} scanned places" \
  || bad "S1 unverified gh secret set (put a verify step before it, or use register-secret-verified.sh)" "$found"

missing=""
for f in skills/handover/common-clauses.md rules/runbook.md hooks/lib/aidd_cc_contract.md; do
  grep -q 'register-secret-verified.sh' "$ROOT/$f" || missing="$missing $f"
done
[[ -z "$missing" ]] && ok "S2 the three declarations name register-secret-verified.sh" || bad "S2 declarations" "missing in:$missing"
S="$ROOT/scripts/register-secret-verified.sh"
[[ -f "$S" ]] && grep -q 'if \[\[ -z "\$ok" \]\]; then' "$S" && grep -q 'no --verify-url' "$S" \
  && ok "S2 the enforcing script exists and has its verify gate and its no-verify refusal" \
  || bad "S2 script" "$S missing or without the gate"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
printf '# steps\n\n1. copy the token\n2. run:\n\n    gh secret set TOKEN --repo o/r < token.txt\n' >"$SB/bad.md"
printf '# steps\n\n1. verify it: curl …/tokens/verify\n2. then:\n\n    gh secret set TOKEN --repo o/r < token.txt\n' >"$SB/good.md"
red="$(scan "$SB/bad.md")"; green="$(scan "$SB/good.md")"
[[ "$red" == *"bad.md:6:"* && -z "$green" ]] && ok "S3 a bare gh secret set is red (bad.md:6), one after a verify line is green" \
  || bad "S3 self-test" "red='$red' green='$green'"

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
