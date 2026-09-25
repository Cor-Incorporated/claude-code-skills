#!/usr/bin/env bash
# The codex column of tests/lib/codex-trust-forms.txt, checked against the real
# Codex CLI.
#
# tests/test-codex-trust-state.sh (CI) proves that the reporter prints what the
# table's reporter column says. That is worth something only while the codex
# column is what Codex really does. The reporter's first parser was written from
# a reading of the config format, not from Codex, and it read hooks that Codex
# skipped as active: `enabled=false`, a final `enabled = false` without a
# newline, and 11 more spellings (review 2026-09-24, measured 2026-09-25). This
# test asks Codex instead of assuming.
#
# Per row: start `codex app-server` with CODEX_HOME in a fresh scratch directory
# (~/.codex is neither read nor written), put hooks.json and the row's
# config.toml there, call hooks/list and classify the probed hook:
#   runs    = enabled, and trustStatus trusted
#   skips   = listed, but not enabled or not trusted
#   rejects = no hook listed, and a config.toml load error reported
# The reporter reads the same two files, so its column is checked here too, with
# real trust keys (absolute paths) instead of the /x/... ones of the CI test.
#
# Local only: CI has no codex CLI. Without one this prints SKIP and exits 0,
# which is a skip, not a pass. Run it after every Codex upgrade.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex CLI not on PATH - the codex column of tests/lib/codex-trust-forms.txt was not checked"
  exit 0
fi

python3 - "$ROOT" <<'PY'
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(sys.argv[1])
FORMS = ROOT / "tests" / "lib" / "codex-trust-forms.txt"
REPORTER = ROOT / "hooks" / "lib" / "codex-trust-state.py"
HOOKS = {"hooks": {
    "PreToolUse": [{"matcher": ".*", "hooks": [
        {"type": "command", "command": "bash /x/.codex/hooks/probed.sh"}]}],
    "SessionStart": [{"hooks": [
        {"type": "command", "command": "bash /x/.codex/hooks/sentinel.sh"}]}],
}}
PROBED = "probed.sh at pre_tool_use:0:0"
SENTINEL = "sentinel.sh at session_start:0:0 (no trust entry)"
TABLE_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\"}


def hooks_list(home):
    """The hooks/list response of a codex app-server whose CODEX_HOME is `home`."""
    env = dict(os.environ, CODEX_HOME=str(home), RUST_LOG="warn",
               CODEX_APP_SERVER_MANAGED_CONFIG_PATH=str(home / "managed_config.toml"))
    proc = subprocess.Popen(
        ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, cwd=home, env=env, text=True)
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in proc.stdout], daemon=True).start()

    def send(message):
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    def call(msg_id, method, params):
        send({"id": msg_id, "method": method, "params": params})
        # One deadline per request, checked on every message: a stream of
        # notifications must not keep a request that never gets a reply alive.
        deadline = time.monotonic() + 60
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"no reply to {method} within 60 s")
            message = json.loads(lines.get(timeout=left))
            if message.get("id") == msg_id:
                return message

    try:
        call(1, "initialize", {"clientInfo": {"name": "codex-trust-conformance", "version": "0"},
                               "capabilities": {"experimentalApi": True}})
        send({"method": "initialized"})
        return call(2, "hooks/list", {"cwds": [str(home)]})
    finally:
        proc.stdin.close()
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def listed(response):
    groups = response.get("result", {}).get("data", [])
    hooks = [hook for group in groups for hook in group.get("hooks", [])]
    errors = [e.get("message", "") for group in groups for e in group.get("errors", [])]
    probed = [hook for hook in hooks if hook.get("key", "").endswith(":pre_tool_use:0:0")]
    return hooks, errors, probed


def codex_verdict(response):
    hooks, errors, probed = listed(response)
    if not hooks and errors:
        return "rejects", errors[0].rsplit("/", 1)[-1]
    if len(probed) != 1:
        return "?", "probed hook not listed: " + json.dumps(response)[:300]
    hook = probed[0]
    runs = hook.get("enabled") and hook.get("trustStatus") in ("trusted", "managed")
    return ("runs" if runs else "skips"), \
        f"enabled={hook.get('enabled')} trustStatus={hook.get('trustStatus')}"


def reporter_verdict(home):
    result = subprocess.run(
        ["python3", str(REPORTER), str(home / "hooks.json"), str(home / "config.toml")],
        capture_output=True, text=True, timeout=60)
    out = [line for line in (result.stdout + result.stderr).splitlines() if line]
    if SENTINEL not in "\n".join(out):
        return "?", "no sentinel line (reporter crashed?): " + " | ".join(out)[:300]
    rest = [line for line in out if SENTINEL not in line]
    if not rest:
        return "quiet", ""
    if len(rest) == 1 and PROBED + " (" in rest[0]:
        return rest[0].split(PROBED + " (", 1)[1].split(")", 1)[0], ""
    return "?", " | ".join(rest)[:300]


def new_home(base, name, config_bytes):
    home = base / name
    home.mkdir()
    (home / "hooks.json").write_text(json.dumps(HOOKS))
    (home / "config.toml").write_bytes(config_bytes)
    return home.resolve()


def rows():
    for line in FORMS.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            yield line.split("|", 3)


def main():
    version = subprocess.run(["codex", "--version"], capture_output=True, text=True).stdout.strip()
    # Resolved up front: Codex keys trust by the hooks.json path it was given.
    base = Path(tempfile.mkdtemp(prefix="codex-trust-conformance-")).resolve()
    try:
        response = hooks_list(new_home(base, "hash", b""))
        _, _, probed = listed(response)
        if len(probed) != 1 or not probed[0].get("currentHash"):
            print("FAIL: hooks/list did not give the probed hook's hash")
            print("  " + json.dumps(response)[:500])
            return 1
        trusted_hash = probed[0]["currentHash"]

        def check(item):
            index, (label, codex, want, config) = item
            name = f"row{index:02d}"
            text = (config.replace("@K@", f"{base / name}/hooks.json:pre_tool_use:0:0")
                    .replace("@H@", trusted_hash))
            # Same escapes, read left to right, as printf %b in the CI test.
            text = re.sub(r"\\([ntr\\])", lambda m: TABLE_ESCAPES[m.group(1)], text)
            try:
                home = new_home(base, name, text.encode("utf-8"))
                got_codex, detail = codex_verdict(hooks_list(home))
                got_reporter, why = reporter_verdict(home)
            except Exception as error:  # a hung or crashed app-server fails its row only
                return label, codex, "?", f"{type(error).__name__}: {error}", want, "?", ""
            return label, codex, got_codex, detail, want, got_reporter, why

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(check, enumerate(rows())))
    finally:
        shutil.rmtree(base, ignore_errors=True)

    failed = 0
    for label, codex, got_codex, detail, want, got_reporter, why in results:
        line = f"{label}: codex {got_codex} ({detail}), reporter {got_reporter}"
        if got_codex == codex and got_reporter == want:
            print(f"PASS: {line}")
            continue
        failed += 1
        print(f"FAIL: {line}")
        print(f"  table: codex {codex}, reporter {want}" + (f" | {why}" if why else ""))
    if not results:
        failed += 1
        print(f"FAIL: no rows in {FORMS}")
    print(f"--- {len(results) - failed} passed, {failed} failed ({version}) ---")
    return 1 if failed else 0


sys.exit(main())
PY
