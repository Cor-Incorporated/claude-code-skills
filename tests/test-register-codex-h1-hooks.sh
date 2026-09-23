#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO_DIR/scripts/register-codex-h1-hooks.py" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

script = sys.argv[1]
passed = 0


def check(ok, description):
    global passed
    if not ok:
        raise AssertionError(description)
    passed += 1
    print("PASS", description)


with tempfile.TemporaryDirectory(prefix="h1-register-") as temp:
    root = pathlib.Path(temp)
    hook_dir = root / "Codex hooks with spaces"
    hook_dir.mkdir()
    h1 = hook_dir / "h1-stall-runtime.sh"
    protect = hook_dir / "protect-branches-codex.sh"
    h1.write_text("#!/bin/bash\n")
    protect.write_text("#!/bin/bash\n")

    def invoke(config):
        return subprocess.run([sys.executable, script, str(config), str(hook_dir)],
                              text=True, capture_output=True)

    fresh = root / "fresh.json"
    result = invoke(fresh)
    check(result.returncode == 0 and "registered" in result.stdout, "fresh registration succeeds")
    data = json.loads(fresh.read_text())
    pre = data["hooks"]["PreToolUse"][0]
    commands = [h["command"] for h in pre["hooks"]]
    check(pre["matcher"] == ".*" and "protect-branches-codex.sh" in commands[0]
          and "h1-stall-runtime.sh" in commands[1], "fresh PreToolUse pair keeps guard order")
    check(len(data["hooks"]["UserPromptSubmit"]) == 1
          and "h1-stall-runtime.sh" in data["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"],
          "fresh UserPromptSubmit points to H1")
    before = fresh.read_bytes()
    check(invoke(fresh).returncode == 0 and fresh.read_bytes() == before,
          "repeat registration leaves bytes unchanged")

    existing = root / "existing.json"
    other = {"type": "command", "command": "bash /tmp/other-hook.sh"}
    initial = {
        "description": "owner text is preserved",
        "hooks": {
            "PreToolUse": [{"matcher": ".*", "hooks": [
                {"type": "command", "command": f"bash '{protect}'"},
                {"type": "command", "command": f"bash '{h1}'"},
                copy.deepcopy(other),
            ]}],
            "UserPromptSubmit": [{"hooks": [copy.deepcopy(other)]}],
            "Stop": [{"hooks": [copy.deepcopy(other)]}],
        },
    }
    existing.write_text(json.dumps(initial))
    check(invoke(existing).returncode == 0, "existing config registration succeeds")
    updated = json.loads(existing.read_text())
    check(updated["hooks"]["PreToolUse"] == initial["hooks"]["PreToolUse"],
          "existing PreToolUse definitions remain unchanged")
    check(updated["description"] == initial["description"]
          and updated["hooks"]["Stop"] == initial["hooks"]["Stop"]
          and updated["hooks"]["UserPromptSubmit"][0] == initial["hooks"]["UserPromptSubmit"][0],
          "other metadata and event definitions remain unchanged")
    check(len(updated["hooks"]["UserPromptSubmit"]) == 2,
          "new H1 UserPromptSubmit group is appended once")

    malformed = root / "malformed.json"
    malformed.write_text("{bad-json")
    prior = malformed.read_bytes()
    check(invoke(malformed).returncode != 0 and malformed.read_bytes() == prior,
          "malformed config fails without mutation")

    missing = root / "missing-h1.json"
    missing.write_text(json.dumps({"hooks": {"PreToolUse": [{"matcher": ".*", "hooks": [
        {"type": "command", "command": f"bash '{protect}'"}
    ]}]}}))
    prior = missing.read_bytes()
    check(invoke(missing).returncode != 0 and missing.read_bytes() == prior,
          "existing config without PreToolUse H1 fails closed")

    duplicate = root / "duplicate.json"
    d = copy.deepcopy(updated)
    d["hooks"]["UserPromptSubmit"].append(copy.deepcopy(d["hooks"]["UserPromptSubmit"][-1]))
    duplicate.write_text(json.dumps(d))
    prior = duplicate.read_bytes()
    check(invoke(duplicate).returncode != 0 and duplicate.read_bytes() == prior,
          "duplicate UserPromptSubmit H1 fails without mutation")

print(f"--- {passed} passed, 0 failed ---")
PY
