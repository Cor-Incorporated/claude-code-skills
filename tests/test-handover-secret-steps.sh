#!/usr/bin/env bash
# Link test (2026-10-31 secret-registration incident, claude-code-skills#473): handover and runbook steps never store a
# secret except through the verify-first script, and the rule's declarations point at that script and reach every
# agent.
#
#   S1 a line with `gh secret set` passes only when it carries (or follows a line carrying) an explicit
#      `<!-- secret-set-ok: <reason> -->` with a non-empty reason. A step that stores a secret names
#      register-secret-verified.sh and has no `gh secret set` of its own. A nearby word "verify" is not enough: the
#      incident's own one-liner (`curl …/tokens/verify; gh secret set …`) had it. Naming the script on the line is not
#      enough either: `register-secret-verified.sh … || gh secret set …` stores exactly when the check refuses (#473
#      review round 2). Scanned: docs/, skills/,
#      rules/, README.md, AGENTS.md, hooks/lib/aidd_cc_contract.md, and every directory in AIDD_HANDOVER_DIRS
#      (colon-separated; e.g. the desktop-handoffs folders, which are outside the repository).
#   S2 skills/handover/common-clauses.md and rules/runbook.md name register-secret-verified.sh; the contract text that
#      hooks/lib/aidd_cc_contract.py delivers to each of codex / cursor / pi / dsh / opencode names it; and the script
#      exists with its verify gate.
#   S3 self-test, file and directory mode: the incident one-liner, a check-less line, a `## 検証` heading nearby, prose
#      saying verify is not needed, the script `|| gh secret set` fallback, the script named on the line before, a
#      marker two lines up and a marker without a reason are red, and so are bare lines under .github/ and in a .json
#      file of a scanned directory; the script line, a marked line and a marker on the same line are green.
#   S4 the recipes (scripts/lib/secret-verify-recipes.json, claude-code-skills#478) keep their shape: a network recipe
#      sends only to its https hosts and carries a negative control on one of its values; a generated recipe has a
#      generator and a check; a consumer recipe pins the consumer's generate and check commands. Every
#      `--recipe <name>` in the scanned places names a recipe that exists. Self-test: a recipe without a control and a
#      step naming an unknown recipe are red.
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
MARK = re.compile(r"<!--\s*secret-set-ok:\s*(?!-->)\S")
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
        if MARK.search(line) or (i > 0 and MARK.search(lines[i - 1])):
            continue
        print("%s:%d: %s" % (p, i + 1, line.strip()[:120]))
PY
}

targets=("$ROOT/docs" "$ROOT/skills" "$ROOT/rules" "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT/hooks/lib/aidd_cc_contract.md")
if [[ -n "${AIDD_HANDOVER_DIRS:-}" ]]; then
  IFS=':' read -r -a extra <<<"$AIDD_HANDOVER_DIRS"
  for d in "${extra[@]}"; do [[ -n "$d" && -e "$d" ]] && targets+=("$d"); done
fi
found="$(scan "${targets[@]}")"
[[ -z "$found" ]] && ok "S1 no gh secret set outside register-secret-verified.sh in ${#targets[@]} scanned places" \
  || bad "S1 gh secret set not through the script (store with register-secret-verified.sh and write no gh secret set on its line, or mark the line with a reason)" "$found"

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
printf '    bash ~/.claude/scripts/register-secret-verified.sh TOKEN o/r --cloudflare-account x || gh secret set TOKEN --repo o/r < t\n' >"$SB/fallback.md"
printf '    bash ~/.claude/scripts/register-secret-verified.sh TOKEN o/r --cloudflare-account x\n    gh secret set TOKEN --repo o/r < t\n' >"$SB/after.md"
printf '<!-- secret-set-ok: a generated value -->\n\n    gh secret set TOKEN --repo o/r < t\n' >"$SB/far.md"
printf '<!-- secret-set-ok: -->\n    gh secret set TOKEN --repo o/r < t\n' >"$SB/noreason.md"
printf '    bash ~/.claude/scripts/register-secret-verified.sh TOKEN o/r --cloudflare-account x\n' >"$SB/script.md"
printf '<!-- secret-set-ok: a generated value, no provider to verify -->\n    openssl rand -hex 32 | gh secret set SALT --repo o/r\n' >"$SB/marked.md"
printf '    openssl rand -hex 32 | gh secret set SALT --repo o/r  <!-- secret-set-ok: a generated value -->\n' >"$SB/inline.md"
reds=""; for f in incident bare heading prose fallback after far noreason; do [[ -n "$(scan "$SB/$f.md")" ]] || reds="$reds $f"; done
greens=""; for f in script marked inline; do [[ -z "$(scan "$SB/$f.md")" ]] || greens="$greens $f"; done
mkdir -p "$SB/tree/.github/workflows"
printf 'run: gh secret set TOKEN --repo o/r < t\n' >"$SB/tree/.github/workflows/x.yml"
printf '{"step": "gh secret set TOKEN --repo o/r < t"}\n' >"$SB/tree/steps.json"
tree_hits="$(scan "$SB/tree" | grep -c .)"
[[ -z "$reds" && -z "$greens" && "$tree_hits" -eq 2 ]] \
  && ok "S3 the incident shapes, the || fallback, the script one line up, a far or empty marker, .github/ and .json are red; the script, a marked line and an inline marker are green" \
  || bad "S3 self-test" "not red:${reds:- none}; not green:${greens:- none}; directory hits ${tree_hits} (want 2)"

# recipes <recipes.json> <dir|file>... → prints one line per defect
recipes() {
  python3 -I - "$ROOT/scripts/lib/access_service_token.py" "$@" <<'PY'
import importlib.util, json, os, re, sys, urllib.parse
from types import SimpleNamespace
module_path, path, places = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    book = json.load(open(path, encoding="utf-8"))["recipes"]
except (OSError, ValueError, KeyError) as exc:
    print("%s: unreadable (%s)" % (path, exc)); sys.exit(0)
def bad_cond(c):
    return (not isinstance(c, dict) or not c or set(c) - {"status", "json"}
            or ("json" in c and (not isinstance(c["json"], dict) or not c["json"]))
            or ("status" in c and not isinstance(c["status"], int)))
for name, r in sorted(book.items()):
    kind, values = r.get("kind"), r.get("values") or []
    if kind == "network":
        req, ctrl = r.get("request") or {}, r.get("control") or {}
        u = urllib.parse.urlsplit(req.get("url", "").replace("{", "").replace("}", ""))
        if u.scheme != "https" or u.hostname not in (r.get("hosts") or []):
            print("%s: url %s is not https on its hosts" % (name, req.get("url")))
        if ctrl.get("replace") not in values or len(set(ctrl) & {"fail_unless", "fail_unless_not"}) != 1:
            print("%s: no negative control on one of its values" % name)
        elif bad_cond(ctrl.get("fail_unless", ctrl.get("fail_unless_not"))):
            print("%s: the control condition is empty or has unknown keys" % name)
        if bad_cond(r.get("pass")):
            print("%s: the pass condition is empty or has unknown keys" % name)
    elif kind == "generated":
        if not r.get("generate") or not r.get("check"):
            print("%s: a generated recipe needs generate and check" % name)
    elif kind == "consumer":
        if not r.get("generate_cmd") or not r.get("check_cmd") or not r.get("repo_marker"):
            print("%s: a consumer recipe needs generate_cmd, check_cmd and repo_marker" % name)
    elif kind == "access-service-token":
        try:
            spec = importlib.util.spec_from_file_location("access_contract", module_path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            def refuse(*_):
                raise ValueError("invalid-access-contract")
            recovering = r.get("operation", "rotate") == "recover"
            params = {"recovery-dir": "/absolute/owner-only/register-secret.attempt"} if recovering else {"rotate-confirmed": "yes"}
            module.config(SimpleNamespace(recipe=r, repo=r.get("repo"), env="", names=r.get("names"),
                                          params=params), refuse)
            if r.get("params") != (["recovery-dir"] if recovering else ["rotate-confirmed"]):
                refuse()
        except Exception:
            print("%s: Access recipe differs from its enforcing four-origin contract" % name)
    else:
        print("%s: unknown kind %r" % (name, kind))
USE = re.compile(r"--recipe\s+([A-Za-z0-9_.-]+)")
files = []
for a in places:
    if os.path.isfile(a):
        files.append(a)
    elif os.path.isdir(a):
        for d, subs, fs in os.walk(a):
            subs[:] = [s for s in subs if s not in (".git", "_unused", "node_modules")]
            files += [os.path.join(d, f) for f in fs if f.endswith((".md", ".sh", ".txt", ".yaml", ".yml", ".json"))]
for f in sorted(files):
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        for m in USE.finditer(line):
            if m.group(1) not in book and m.group(1) not in ("<name>", "name"):
                print("%s:%d: unknown recipe %s" % (f, i + 1, m.group(1)))
PY
}
RECIPES="$ROOT/scripts/lib/secret-verify-recipes.json"
defects="$(recipes "$RECIPES" "${targets[@]}")"
[[ -z "$defects" ]] && ok "S4 every recipe keeps its shape (network recipes carry a negative control) and every --recipe in ${#targets[@]} places exists" \
  || bad "S4 recipes" "$defects"
python3 -I - "$RECIPES" "$SB/nocontrol.json" <<'PY'
import json, sys
book = json.load(open(sys.argv[1]))
book["recipes"]["github-oauth"].pop("control")
json.dump(book, open(sys.argv[2], "w"))
book = json.load(open(sys.argv[1]))
book["recipes"]["slack-oauth"]["control"]["fail_unless"] = {"jsno": {"error": "bad_client_secret"}}
book["recipes"]["github-oauth"]["pass"] = {}
json.dump(book, open(sys.argv[2].replace("nocontrol", "badcond"), "w"))
book = json.load(open(sys.argv[1]))
book["recipes"]["access-service-token"]["origins"].pop()
json.dump(book, open(sys.argv[2].replace("nocontrol", "badaccess"), "w"))
PY
printf '    bash ~/.claude/scripts/register-secret-verified.sh --recipe github-oauth-v9 A B o/r\n' >"$SB/unknown.md"
r1="$(recipes "$SB/nocontrol.json" "$SB/none.md")"; r2="$(recipes "$RECIPES" "$SB/unknown.md")"; r3="$(recipes "$SB/badcond.json" "$SB/none.md")"
r4="$(recipes "$SB/badaccess.json" "$SB/none.md")"
[[ "$r1" == *"github-oauth: no negative control"* && "$r2" == *"unknown recipe github-oauth-v9"* \
   && "$r3" == *"slack-oauth: the control condition is empty or has unknown keys"* && "$r3" == *"github-oauth: the pass condition is empty or has unknown keys"* \
   && "$r4" == *"access-service-token: Access recipe differs from its enforcing four-origin contract"* ]] \
  && ok "S4 self-test: missing control, misspelled/empty condition, missing Access origin and unknown recipe are red" \
  || bad "S4 self-test" "no-control: ${r1:-green}; unknown: ${r2:-green}; bad conditions: ${r3:-green}; bad Access: ${r4:-green}"
grep -q 'unknown recipe %r' "$ROOT/scripts/lib/secret_recipes.py" && grep -q 'if not ok:' "$ROOT/scripts/lib/secret_recipes.py" \
  && ok "S4 the enforcing helper refuses an unknown recipe and has its control gate" || bad "S4 helper" "secret_recipes.py lost its gates"

echo "--- $pass passed, $fail failed ---"
[[ $fail -eq 0 ]]
