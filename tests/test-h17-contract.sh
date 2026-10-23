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

AGENTS = ("codex", "cursor", "opencode", "pi", "dsh")
controls = (root / "hooks/lib/aidd_cc_controls.py").read_text(encoding="utf-8")

def oracle_problems(text: str, codes: bool) -> list[str]:
    """What the oracle would reject in one rendered contract (empty list = consistent). `codes`: the entry reports
    exit codes (aidd_cc.CODE_REPORTING_AGENTS), so the gate wants the command alone; otherwise `<cmd>; echo exit=$?`."""
    out = []
    for value in ("complete", "partial", "unverified"):
        line = f"Status: {value}"
        if f"`{line}`" not in text:
            out.append(f"contract lacks `{line}`")
        elif T.declared_status(f"done.\n\n{line}") != value:
            out.append(f"oracle reads `{line}` as {T.declared_status(chr(10).join(['done.', line]))!r}")
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
    if codes:
        if "on its own" not in text or "echo exit=$?" in text or "run the command on its own" not in controls:
            out.append(f"code-reporting entry: contract says 'on its own'={'on its own' in text}, mentions echo={'echo exit=$?' in text}; gate advice has 'run the command on its own'={'run the command on its own' in controls}")
    elif "`<command>; echo exit=$?`" not in text or "run it as `<cmd>; echo exit=$?`" not in controls:
        out.append(f"no-code entry: contract has the echo form={'`<command>; echo exit=$?`' in text}; gate advice has it={'run it as `<cmd>; echo exit=$?`' in controls}")
    return out

for agent in AGENTS:
    problems = oracle_problems(C.contract(agent), C.reports_codes(agent))
    check(f"{agent}: the contract goes through the oracle's own patterns, parser and exit-status advice", not problems, "; ".join(problems))
import aidd_cc as A  # noqa: E402
check("the contract reads the same CODE_REPORTING_AGENTS as the oracle imports",
      {a for a in AGENTS if C.reports_codes(a)} == {a for a in AGENTS if a in A.CODE_REPORTING_AGENTS},
      f"contract={sorted(a for a in AGENTS if C.reports_codes(a))} oracle={sorted(A.CODE_REPORTING_AGENTS)}")
mutated = oracle_problems(C.contract("pi").replace("Status: complete", "Status: done"), True)
check("a mutated contract (`Status: done`) fails the same check", bool(mutated), "the check did not notice")
swapped = oracle_problems(C.contract("cursor"), True)
check("the no-code text given to a code-reporting entry fails the same check", bool(swapped), "the check did not notice")

quality = (root / "rules" / "quality.md").read_text(encoding="utf-8")
missing = [k for k in ("Status: complete | partial | unverified", "Evidence: <", "Readback: <path> sha256=") if k not in quality]
check("rules/quality.md names the same Status / Evidence / Readback lines", not missing, f"quality.md lacks {missing}")

# installer behaviour on scratch files
own = sb / "own.md"; own.write_text("# Owner rules\nkeep me\n", encoding="utf-8")
(first, _), (second, _) = C.install(own, "pi"), C.install(own, "pi")
body1 = own.read_text(encoding="utf-8")
check("installer keeps the owner's lines and adds the block once",
      first == "updated" and second == "unchanged" and body1.startswith("# Owner rules\nkeep me\n")
      and body1.count(C.BEGIN) == 1 and body1.endswith(C.block("pi")), f"first={first} second={second}")
own.write_text(body1.replace("H17 checks", "H17 maybe checks") + "owner tail\n", encoding="utf-8")
third, _ = C.install(own, "pi"); body3 = own.read_text(encoding="utf-8")
check("an edited block is restored and text after it is kept",
      third == "updated" and C.block("pi") in body3 and body3.endswith("owner tail\n"), f"third={third}")
legacy = sb / "legacy.md"; legacy.write_text("<!-- Deployed by claude-code-skills setup.sh from dsh/AGENTS.md -->\n# old\n", encoding="utf-8")
check("the #440 whole-file copy is replaced by the block", C.install(legacy, "dsh")[0] == "updated" and legacy.read_text() == C.block("dsh"))
fresh = sb / "new" / "AGENTS.md"
check("a missing file is created with the block", C.install(fresh, "opencode")[0] == "created" and fresh.read_text() == C.block("opencode"))
broken = sb / "broken.md"; broken.write_text(f"x\n{C.BEGIN}\nhalf\n", encoding="utf-8")
p = subprocess.run([sys.executable, "-I", str(root / "hooks/lib/aidd_cc_contract.py"), "install", "--agent", "pi", str(broken)], capture_output=True, text=True)
check("unbalanced markers are refused and the file is left as it was",
      p.returncode == 2 and broken.read_text() == f"x\n{C.BEGIN}\nhalf\n", f"rc={p.returncode} stderr={p.stderr.strip()}")
for agent, expect_override in (("codex", True), ("pi", True), ("dsh", False), ("opencode", False)):
    d = sb / f"ov-{agent}"; d.mkdir()
    (d / "AGENTS.override.md").write_text("# my override\n", encoding="utf-8")
    _, dest = C.install(d / "AGENTS.md", agent)
    want = d / ("AGENTS.override.md" if expect_override else "AGENTS.md")
    check(f"{agent}: a non-empty AGENTS.override.md {'receives' if expect_override else 'does not take'} the block", dest == want, f"dest={dest.name}")
empty = sb / "ov-empty"; empty.mkdir(); (empty / "AGENTS.override.md").write_text("\n", encoding="utf-8")
check("an empty AGENTS.override.md is skipped (Codex and Pi read the first non-empty file)", C.install(empty / "AGENTS.md", "codex")[1].name == "AGENTS.md")

# deploy wiring
setup = (root / "setup.sh").read_text(encoding="utf-8")
lines = {"codex": ".codex/AGENTS.md", "opencode": ".opencode-2/config/opencode/AGENTS.md", "pi": ".pi/agent/AGENTS.md", "dsh": ".dsh-aidd/AGENTS.md"}
missing = [a for a, path in lines.items() if not re.search(rf"contract_install {a} \"\$HOME/{re.escape(path)}\"", setup)]
check("setup.sh installs each entry's text into its documented file", not missing, f"missing {missing}")
reg = (root / "scripts/register-aidd-cc-hooks.py").read_text(encoding="utf-8")
check("Cursor's sessionStart is registered", '"sessionStart"' in reg[reg.index("CURSOR_EVENTS"):reg.index(")", reg.index("CURSOR_EVENTS"))])
out = subprocess.run(["bash", str(root / "hooks/cursor/aidd-cc-cursor.sh")], input='{"hook_event_name":"sessionStart","conversation_id":"t"}',
                     capture_output=True, text=True, env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(sb),
                     "AIDD_CC_PY": str(root / "hooks/lib/aidd_cc.py"), "AIDD_LEDGER_PATH": str(sb / "l.jsonl")})
try:
    ctx = json.loads(out.stdout).get("additional_context", "")
except ValueError:
    ctx = ""
check("Cursor's sessionStart hook returns the cursor contract as additional_context", ctx.strip() == C.contract("cursor"), f"stdout={out.stdout[:80]!r}")

# Following the rendered text must pass the real gate on that entry, and the other style must not (Codex review P1:
# "alone, no echo" on Cursor, which reports no exit code, was answered UNKNOWN).
def cursor_verdict(run_cmd: str, out_text: str, tag: str) -> str:
    env = {**__import__("os").environ, "AIDD_CC_STATE_DIR": str(sb / f"st-{tag}"), "AIDD_LEDGER_PATH": str(sb / "l.jsonl"),
           "AIDD_LEDGER_SOURCE": "test", "AIDD_CC_PY": str(root / "hooks/lib/aidd_cc.py")}
    hook = str(root / "hooks/cursor/aidd-cc-cursor.sh")
    report = "Tests pass.\nEvidence: python3 -m pytest -q | 1 passed | 2026-10-23T08:10:00Z\nStatus: complete"
    for ev in ({"hook_event_name": "beforeShellExecution", "command": run_cmd},
               {"hook_event_name": "afterShellExecution", "command": run_cmd, "output": out_text},
               {"hook_event_name": "afterAgentResponse", "text": report}):
        subprocess.run(["bash", hook], input=json.dumps({**ev, "conversation_id": f"c-{tag}"}), capture_output=True, text=True, env=env)
    return subprocess.run(["bash", hook], input=json.dumps({"hook_event_name": "stop", "conversation_id": f"c-{tag}", "status": "completed"}),
                          capture_output=True, text=True, env=env).stdout.strip()

echo_style = "`<command>; echo exit=$?`" in C.contract("cursor")
follow = cursor_verdict("python3 -m pytest -q; echo exit=$?" if echo_style else "python3 -m pytest -q", "1 passed\nexit=0" if echo_style else "1 passed", "follow")
other = cursor_verdict("python3 -m pytest -q" if echo_style else "python3 -m pytest -q; echo exit=$?", "1 passed" if echo_style else "1 passed\nexit=0", "other")
check("on Cursor, a report that follows its contract is accepted by the gate and the other style is not",
      follow == "{}" and "followup_message" in other, f"follow={follow[:90]!r} other={other[:90]!r}")

print(f"h17 contract: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
PY
