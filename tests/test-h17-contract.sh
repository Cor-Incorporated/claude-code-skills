#!/usr/bin/env bash
# H17 report contract for the non-Claude entries (hooks/lib/aidd_cc_contract.md, owner decision 2026-10-23).
# Ties the one contract text to what enforces it, so a change on one side fails here with both values:
#   - its Status / Evidence / Readback lines go through the oracle's own patterns and parser (aidd_cc_text.py),
#     and its run-alone wording matches the gate's advice (aidd_cc_controls.py);
#   - rules/quality.md (Claude Code's copy of the contract) names the same three line kinds;
#   - the installer keeps an owner's lines, is idempotent, migrates the #440 whole-file copy, refuses broken markers;
#   - setup.sh installs into the four documented files, and Cursor's sessionStart hook returns the same text.
# A mutated contract must fail the same checks, or they prove nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
python3 -I - "$ROOT" "$SB" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

root, sb = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "hooks" / "lib"))
import aidd_cc_contract as C  # noqa: E402
import aidd_cc_text as T  # noqa: E402

results = []
def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok else f" — {detail}"))

def oracle_problems(text: str) -> list[str]:
    """What the oracle would reject in the contract's own example lines (empty list = consistent)."""
    out = []
    for value in ("complete", "partial", "unverified"):
        line = f"Status: {value}"
        if f"`{line}`" not in text:
            out.append(f"contract lacks `{line}`")
        elif T.declared_status(f"done.\n\n{line}") != value:
            out.append(f"oracle reads `{line}` as {T.declared_status(f'done.{chr(10)}{line}')!r}")
    ev = re.search(r"`(Evidence: [^`]+)`", text)
    sample_ev = "Evidence: python3 -m pytest -q | 3 passed in 0.01s | 2026-10-23T06:00:00Z"
    if not ev or ev.group(1).count(" | ") != 2:
        out.append(f"Evidence template is not `cmd | output | time`: {ev.group(1) if ev else 'missing'!r}")
    elif T.evidence_trailers(sample_ev) != [("python3 -m pytest -q", "3 passed in 0.01s", "2026-10-23T06:00:00Z")]:
        out.append(f"oracle parses the Evidence shape as {T.evidence_trailers(sample_ev)!r}")
    rb = re.search(r"`(Readback: [^`]+)`", text)
    if not rb or "sha256=" not in rb.group(1):
        out.append(f"Readback template lacks sha256=: {rb.group(1) if rb else 'missing'!r}")
    elif not T.READBACK_LINE_RE.search("Readback: /tmp/x.txt sha256=" + "a" * 64):
        out.append("oracle READBACK_LINE_RE rejects the Readback shape")
    advice = re.search(r"run the command on its own", (root / "hooks/lib/aidd_cc_controls.py").read_text())
    if "on its own" not in text or not advice:
        out.append(f"run-alone wording: contract={'on its own' in text}, gate advice={bool(advice)}")
    return out

text = C.contract()
problems = oracle_problems(text)
check("contract lines go through the oracle's own patterns and parser", not problems, "; ".join(problems))
mutated = oracle_problems(text.replace("Status: complete", "Status: done"))
check("a mutated contract (`Status: done`) fails the same check", bool(mutated), "the check did not notice")

quality = (root / "rules" / "quality.md").read_text(encoding="utf-8")
missing = [k for k in ("Status: complete | partial | unverified", "Evidence: <", "Readback: <path> sha256=") if k not in quality]
check("rules/quality.md names the same Status / Evidence / Readback lines", not missing, f"quality.md lacks {missing}")

# installer behaviour on scratch files
own = sb / "own.md"; own.write_text("# Owner rules\nkeep me\n", encoding="utf-8")
first = C.install(own); body1 = own.read_text(encoding="utf-8")
second = C.install(own)
check("installer keeps the owner's lines and adds the block once",
      first == "updated" and second == "unchanged" and body1.startswith("# Owner rules\nkeep me\n")
      and body1.count(C.BEGIN) == 1 and body1.endswith(C.block()), f"first={first} second={second}")
own.write_text(body1.replace("H17 checks", "H17 maybe checks") + "owner tail\n", encoding="utf-8")
third = C.install(own); body3 = own.read_text(encoding="utf-8")
check("an edited block is restored and text after it is kept",
      third == "updated" and C.block() in body3 and body3.endswith("owner tail\n"), f"third={third}")
legacy = sb / "legacy.md"; legacy.write_text("<!-- Deployed by claude-code-skills setup.sh from dsh/AGENTS.md -->\n# old\n", encoding="utf-8")
check("the #440 whole-file copy is replaced by the block", C.install(legacy) == "updated" and legacy.read_text() == C.block())
fresh = sb / "new" / "AGENTS.md"
check("a missing file is created with the block", C.install(fresh) == "created" and fresh.read_text() == C.block())
broken = sb / "broken.md"; broken.write_text(f"x\n{C.BEGIN}\nhalf\n", encoding="utf-8")
p = subprocess.run([sys.executable, "-I", str(root / "hooks/lib/aidd_cc_contract.py"), "install", str(broken)], capture_output=True, text=True)
check("unbalanced markers are refused and the file is left as it was",
      p.returncode == 2 and broken.read_text() == f"x\n{C.BEGIN}\nhalf\n", f"rc={p.returncode} stderr={p.stderr.strip()}")

# deploy wiring
setup = (root / "setup.sh").read_text(encoding="utf-8")
targets = [".codex/AGENTS.md", ".opencode-2/config/opencode/aidd-h17-contract.md", ".pi/agent/AGENTS.md", ".dsh-aidd/AGENTS.md"]
# OpenCode 2.x: the guardrails launcher replaces the global config dir (OPENCODE_CONFIG_DIR), so the contract must be
# listed in `instructions` of the 2.x user config that guardrails hands back through OPENCODE_CONFIG
snippet = setup[setup.index("<<'PY_OC2'\n") + len("<<'PY_OC2'\n") : setup.index("\nPY_OC2\n")]
oc2 = sb / "oc2" / "opencode.json"; oc2.parent.mkdir(parents=True)
oc2.write_text(json.dumps({"model": "deepseek/deepseek-flash", "plugins": ["/p/aidd-cc-v2"]}), encoding="utf-8")
contract_file = str(sb / "oc2" / "aidd-h17-contract.md")
for _ in (1, 2):
    subprocess.run([sys.executable, "-I", "-", str(oc2), "/p/aidd-cc-v2", contract_file], input=snippet, text=True, check=True)
cfg = json.loads(oc2.read_text(encoding="utf-8"))
check("setup.sh lists the 2.x contract file in `instructions` once and keeps the other keys",
      cfg.get("instructions") == [contract_file] and cfg.get("plugins") == ["/p/aidd-cc-v2"] and cfg.get("model") == "deepseek/deepseek-flash",
      f"config={cfg}")
check("setup.sh installs into the four documented files", all(t in setup for t in targets) and "aidd_cc_contract.py\" install" in setup,
      f"missing {[t for t in targets if t not in setup]}")
reg = (root / "scripts/register-aidd-cc-hooks.py").read_text(encoding="utf-8")
check("Cursor's sessionStart is registered", '"sessionStart"' in reg[reg.index("CURSOR_EVENTS"):reg.index(")", reg.index("CURSOR_EVENTS"))])
out = subprocess.run(["bash", str(root / "hooks/cursor/aidd-cc-cursor.sh")], input='{"hook_event_name":"sessionStart","conversation_id":"t"}',
                     capture_output=True, text=True, env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(sb),
                     "AIDD_CC_PY": str(root / "hooks/lib/aidd_cc.py"), "AIDD_LEDGER_PATH": str(sb / "l.jsonl")})
try:
    ctx = json.loads(out.stdout).get("additional_context", "")
except ValueError:
    ctx = ""
check("Cursor's sessionStart hook returns the contract as additional_context", ctx.strip() == text, f"stdout={out.stdout[:80]!r}")

print(f"h17 contract: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
PY
