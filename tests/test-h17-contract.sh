#!/usr/bin/env bash
# H17 report contract for the non-Claude entries (hooks/lib/aidd_cc_contract.md, owner decision 2026-10-23).
# Ties the one contract text to what enforces it, so a change on one side fails here with both values:
#   - its Status / Evidence / Readback lines go through the oracle's own patterns and parser (aidd_cc_text.py);
#   - each entry's exit-status paragraph is the one its real gate accepts: a report that follows it passes, and the
#     other style is blocked (Cursor and Codex through their hooks, Pi / dsh / OpenCode through the oracle);
#   - rules/quality.md (Claude Code's copy of the contract) names the same three line kinds;
#   - the installer keeps an owner's lines, is idempotent, migrates the #440 copy, refuses broken markers, and writes
#     to the file each tool's loader picks; OpenCode's file is listed in its config's `instructions`;
#   - setup.sh wires every target, and Cursor's sessionStart hook returns Cursor's text.
# A mutated contract must fail the same checks, or they prove nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
python3 -I - "$ROOT" "$SB" <<'PY'
import json, os, re, subprocess, sys
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
REPORT = "Tests pass.\nEvidence: python3 -m pytest -q | 1 passed | 2026-10-23T08:10:00Z\nStatus: complete"
ALONE, ECHO = "python3 -m pytest -q", "python3 -m pytest -q; echo exit=$?"

def line_problems(text: str) -> list[str]:
    """What the oracle's own patterns reject in the contract's Status / Evidence / Readback lines."""
    out = []
    for value in ("complete", "partial", "unverified"):
        line = f"Status: {value}"
        if f"`{line}`" not in text:
            out.append(f"contract lacks `{line}`")
        elif T.declared_status(f"done.\n\n{line}") != value:
            out.append(f"oracle reads `{line}` as {T.declared_status(chr(10).join(['done.', line]))!r}")
    ev = re.search(r"`(Evidence: [^`]+)`", text)
    sample = "Evidence: python3 -m pytest -q | 3 passed in 0.01s | 2026-10-23T06:00:00Z"
    if not ev or ev.group(1).count(" | ") != 2:
        out.append(f"Evidence template is not `cmd | output | time`: {ev.group(1) if ev else 'missing'!r}")
    elif T.evidence_trailers(sample) != [("python3 -m pytest -q", "3 passed in 0.01s", "2026-10-23T06:00:00Z")]:
        out.append(f"oracle parses the Evidence shape as {T.evidence_trailers(sample)!r}")
    rb = re.search(r"`(Readback: [^`]+)`", text)
    if not rb or "sha256=" not in rb.group(1) or not T.READBACK_LINE_RE.search("Readback: /tmp/x sha256=" + "a" * 64):
        out.append(f"Readback template / pattern mismatch: {rb.group(1) if rb else 'missing'!r}")
    return out

def run_style(text: str) -> str:
    return ECHO if "`<command>; echo exit=$?`" in text else ALONE

def env(tag):
    return {**os.environ, "AIDD_CC_STATE_DIR": str(sb / f"st-{tag}"), "AIDD_LEDGER_PATH": str(sb / "l.jsonl"),
            "AIDD_LEDGER_SOURCE": "test", "AIDD_CC_PY": str(root / "hooks/lib/aidd_cc.py")}

def hook(script, payload, tag):
    return subprocess.run(["bash", str(root / script)], input=json.dumps(payload), capture_output=True, text=True, env=env(tag)).stdout.strip()

def verdict(agent: str, cmd: str, tag: str) -> bool:
    """True when the real gate on `agent` accepts REPORT after `cmd` ran successfully (1 passed, exit 0)."""
    out = "1 passed\nexit=0" if cmd == ECHO else "1 passed"
    if agent == "cursor":
        for ev in ({"hook_event_name": "beforeShellExecution", "command": cmd},
                   {"hook_event_name": "afterShellExecution", "command": cmd, "output": out},
                   {"hook_event_name": "afterAgentResponse", "text": REPORT}):
            hook("hooks/cursor/aidd-cc-cursor.sh", {**ev, "conversation_id": tag}, tag)
        return hook("hooks/cursor/aidd-cc-cursor.sh", {"hook_event_name": "stop", "conversation_id": tag, "status": "completed"}, tag) == "{}"
    if agent == "codex":  # Codex sends the exit code with the shell result (measured: 1339 of 1349 rows)
        base = {"session_id": tag, "tool_name": "exec_command", "tool_input": {"cmd": cmd}}
        hook("hooks/codex/aidd-cc-codex.sh", {**base, "hook_event_name": "PreToolUse"}, tag)
        hook("hooks/codex/aidd-cc-codex.sh", {**base, "hook_event_name": "PostToolUse", "tool_response": {"exit_code": 0, "stdout": out}}, tag)
        return "block" not in hook("hooks/codex/aidd-cc-codex.sh", {"hook_event_name": "Stop", "session_id": tag, "last_assistant_message": REPORT}, tag)
    oracle = [sys.executable, "-I", str(root / "hooks/lib/aidd_cc.py")]
    call = {"session_id": tag, "tool_name": "bash", "tool_input": {"command": cmd}}
    subprocess.run([*oracle, "pre", "--agent", agent], input=json.dumps(call), capture_output=True, text=True, env=env(tag))
    subprocess.run([*oracle, "post", "--agent", agent], input=json.dumps({**call, "tool_response": {"exit_code": 0, "stdout": out}}),
                   capture_output=True, text=True, env=env(tag))
    v = subprocess.run([*oracle, "stop", "--agent", agent], input=json.dumps({"session_id": tag, "last_assistant_message": REPORT}),
                       capture_output=True, text=True, env=env(tag)).stdout.strip().splitlines()
    return bool(v) and json.loads(v[-1]).get("decision") != "block"

for agent in AGENTS:
    text = C.contract(agent)
    problems = line_problems(text)
    check(f"{agent}: Status / Evidence / Readback lines go through the oracle's own patterns", not problems, "; ".join(problems))
    follow = run_style(text)
    other = ALONE if follow == ECHO else ECHO
    ok_follow, ok_other = verdict(agent, follow, f"{agent}-f"), verdict(agent, other, f"{agent}-o")
    check(f"{agent}: a report that follows its text ({'echo' if follow == ECHO else 'alone'}) passes the real gate, the other style does not",
          ok_follow and not ok_other, f"follow accepted={ok_follow}, other accepted={ok_other}")
check("a mutated contract (`Status: done`) fails the line check", bool(line_problems(C.contract("pi").replace("Status: complete", "Status: done"))))
check("Cursor's text given to Pi would be rejected by Pi's gate", not verdict("pi", run_style(C.contract("cursor")), "swap"))

quality = (root / "rules" / "quality.md").read_text(encoding="utf-8")
missing = [k for k in ("Status: complete | partial | unverified", "Evidence: <", "Readback: <path> sha256=") if k not in quality]
check("rules/quality.md names the same Status / Evidence / Readback lines", not missing, f"quality.md lacks {missing}")

# installer behaviour on scratch files
own = sb / "own.md"; own.write_text("# Owner rules\nkeep me\n", encoding="utf-8")
(first, _), (second, _) = C.install(own, "dsh"), C.install(own, "dsh")
body1 = own.read_text(encoding="utf-8")
check("installer keeps the owner's lines and adds the block once",
      first == "updated" and second == "unchanged" and body1.startswith("# Owner rules\nkeep me\n")
      and body1.count(C.BEGIN) == 1 and body1.endswith(C.block("dsh")), f"first={first} second={second}")
own.write_text(body1.replace("H17 checks", "H17 maybe checks") + "owner tail\n", encoding="utf-8")
third, _ = C.install(own, "dsh"); body3 = own.read_text(encoding="utf-8")
check("an edited block is restored and text after it is kept",
      third == "updated" and C.block("dsh") in body3 and body3.endswith("owner tail\n"), f"third={third}")
legacy = sb / "legacy.md"; legacy.write_text("<!-- Deployed by claude-code-skills setup.sh from dsh/AGENTS.md -->\n# old\n", encoding="utf-8")
check("the #440 whole-file copy is replaced by the block", C.install(legacy, "dsh")[0] == "updated" and legacy.read_text() == C.block("dsh"))
fresh = sb / "new" / "AGENTS.md"
check("a missing file is created with the block", C.install(fresh, "dsh")[0] == "created" and fresh.read_text() == C.block("dsh"))
broken = sb / "broken.md"; broken.write_text(f"x\n{C.BEGIN}\nhalf\n", encoding="utf-8")
p = subprocess.run([sys.executable, "-I", str(root / "hooks/lib/aidd_cc_contract.py"), "install", "--agent", "dsh", str(broken)], capture_output=True, text=True)
check("unbalanced markers are refused and the file is left as it was",
      p.returncode == 2 and broken.read_text() == f"x\n{C.BEGIN}\nhalf\n", f"rc={p.returncode} stderr={p.stderr.strip()}")

def picked(agent, files, n):
    d = sb / f"pick-{n}"; d.mkdir()
    for name, body in files.items():
        (d / name).write_text(body, encoding="utf-8")
    return C.install(d / "AGENTS.md", agent)[1].name
cases = [  # (agent, existing files, the file the tool's loader reads)
    ("pi", {"AGENTS.override.md": "\n", "AGENTS.md": "# mine\n"}, "AGENTS.override.md"),  # pi: first EXISTING, even empty
    ("pi", {"CLAUDE.md": "# my rules\n"}, "CLAUDE.md"),  # a new AGENTS.md would hide the owner's CLAUDE.md
    ("pi", {}, "AGENTS.md"),
    ("codex", {"AGENTS.override.md": "# mine\n"}, "AGENTS.override.md"),  # codex: first NON-EMPTY
    ("codex", {"AGENTS.override.md": "\n", "AGENTS.md": "# mine\n"}, "AGENTS.md"),
    ("dsh", {"AGENTS.override.md": "# mine\n"}, "AGENTS.md"),
]
for n, (agent, files, want) in enumerate(cases):
    got = picked(agent, files, n)
    check(f"{agent} with {sorted(files) or 'no files'}: the block goes to {want}", got == want, f"got {got}")

cfg = sb / "opencode.json"; cfg.write_text('{"$schema": "https://opencode.ai/config.json", "plugins": ["x"]}\n', encoding="utf-8")
inst = sb / "aidd-h17-contract.md"
r1, r2 = C.register_opencode(cfg, inst), C.register_opencode(cfg, inst)
data = json.loads(cfg.read_text())
check("OpenCode: the contract file is listed in `instructions` once and other keys are kept",
      (r1, r2) == ("updated", "unchanged") and data["instructions"] == [str(inst)] and data["plugins"] == ["x"], f"{r1},{r2},{data}")
private = sb / "private.json"; private.write_text("{}", encoding="utf-8"); private.chmod(0o600)
C.register_opencode(private, inst)
check("OpenCode: the config keeps its own permissions (0600 stays 0600)", oct(private.stat().st_mode & 0o777) == "0o600",
      f"mode={oct(private.stat().st_mode & 0o777)}")
bad = sb / "bad.json"; bad.write_text('{"instructions": "x"}', encoding="utf-8")
p = subprocess.run([sys.executable, "-I", str(root / "hooks/lib/aidd_cc_contract.py"), "register-opencode", str(bad), str(inst)], capture_output=True, text=True)
check("OpenCode: a config whose `instructions` is not a list is refused and left alone",
      p.returncode == 2 and bad.read_text() == '{"instructions": "x"}', f"rc={p.returncode}")

# deploy wiring: run setup.sh's own contract block in a scratch HOME, with a non-default Pi agent dir and an opencode.jsonc
setup = (root / "setup.sh").read_text(encoding="utf-8")
snippet = setup[setup.index("# H17 report contract (owner decision"):setup.index("# Entry launchers (2026-10-18)")]
home = sb / "home"
for d in (".codex", "pi-custom", ".dsh-aidd", ".opencode-2/config/opencode"):
    (home / d).mkdir(parents=True, exist_ok=True)
(home / ".opencode-2/config/opencode/opencode.json").write_text('{"plugins": []}\n', encoding="utf-8")
(home / ".opencode-2/config/opencode/opencode.jsonc").write_text('{"plugins": ["guardrails"]}\n', encoding="utf-8")
run_env = {k: v for k, v in os.environ.items() if k not in ("CODEX_HOME", "XDG_CONFIG_HOME", "PI_CODING_AGENT_DIR", "OPENCODE_CONFIG")}
run_env["OPENCODE_CONFIG"] = str(home / ".config/opencode/opencode.jsonc")  # what setup.sh itself sets for the 1.x opencode
run_env.update({"HOME": str(home), "REPO_DIR": str(root), "PI_CODING_AGENT_DIR": str(home / "pi-custom")})
r = subprocess.run(["bash", "-euo", "pipefail", "-c", snippet], capture_output=True, text=True, env=run_env)
oc = home / ".opencode-2/config/opencode"
placed = {"codex": home / ".codex/AGENTS.md", "pi (PI_CODING_AGENT_DIR)": home / "pi-custom/AGENTS.md", "dsh": home / ".dsh-aidd/AGENTS.md",
          "opencode file": oc / "aidd-h17-contract.md"}
wrong = [k for k, f in placed.items() if not (f.is_file() and C.BEGIN in f.read_text(encoding="utf-8"))]
jsonc = json.loads((oc / "opencode.jsonc").read_text()); plain = json.loads((oc / "opencode.json").read_text())
check("setup.sh's block puts each entry's text where its tool and launcher look",
      r.returncode == 0 and not wrong and not (home / ".pi/agent/AGENTS.md").exists(), f"rc={r.returncode} missing={wrong} stderr={r.stderr.strip()[:120]}")
check("OpenCode: with opencode.jsonc present, the instructions go into the .jsonc that guardrails selects",
      jsonc.get("instructions") == [str(oc / "aidd-h17-contract.md")] and "instructions" not in plain, f"jsonc={jsonc} json={plain}")
check("OpenCode: the 1.x OPENCODE_CONFIG that setup.sh exports is not where the 2.x instructions go",
      not (home / ".config/opencode/opencode.jsonc").exists(), "setup wrote the 1.x config")
reg = (root / "scripts/register-aidd-cc-hooks.py").read_text(encoding="utf-8")
check("Cursor's sessionStart is registered", '"sessionStart"' in reg[reg.index("CURSOR_EVENTS"):reg.index(")", reg.index("CURSOR_EVENTS"))])
out = hook("hooks/cursor/aidd-cc-cursor.sh", {"hook_event_name": "sessionStart", "conversation_id": "t"}, "ss")
try:
    ctx = json.loads(out).get("additional_context", "")
except ValueError:
    ctx = ""
check("Cursor's sessionStart hook returns Cursor's text as additional_context", ctx.strip() == C.contract("cursor"), f"stdout={out[:80]!r}")

print(f"h17 contract: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
PY
