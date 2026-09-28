#!/usr/bin/env bash
# Differential fuzz of hooks/lib/codex-trust-state.py against tomllib.
#
# The reporter reads config.toml with its own line reader, because it must run on
# the Python 3.9 that macOS ships, which has no tomllib. Review of that reader
# (2026-09-25) kept finding valid TOML spellings of a trust entry that Codex reads
# as disabled or untrusted while the reporter read them as active. Codex's own
# verdict is in tests/lib/codex-trust-forms.txt (one row per spelling); this test
# covers the combinations of spellings instead: whitespace, quoting and escapes,
# dotted keys, inline tables, multi-line strings and arrays holding text that
# looks like keys or headers, comments, CRLF, a byte order mark, and a leftover
# entry of the wrong type elsewhere.
#
# Reference: tomllib parses the file, then Codex CLI 0.156.0's rules decide
# (codex-rs/hooks/src/engine/discovery.rs, hook_enabled / hook_trust_status):
#   rejects - any entry is not a table, or has enabled not a boolean or
#             trusted_hash not a string: Codex refuses the whole file
#   skips   - no entry for the hook, enabled = false, or no trusted_hash
#   runs    - otherwise
# Files tomllib rejects are not compared (Codex refuses those too).
#
# Fails on any config where the reference says skips or rejects and the reporter
# stays quiet (the direction of the 2026-09-01 outage), on any false alarm, and
# on any exception. Reports that name another reason are counted, not failed.
# Without tomllib (Python < 3.11) this prints SKIP and exits 0: a skip, not a pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! python3 -c 'import tomllib' 2>/dev/null; then
  echo "SKIP: python3 $(python3 -c 'import platform; print(platform.python_version())') has no tomllib - the fuzz did not run"
  exit 0
fi

python3 - "$ROOT/hooks/lib/codex-trust-state.py" <<'PY'
import importlib.util
import os
import random
import sys
import tempfile
import tomllib

spec = importlib.util.spec_from_file_location("codex_trust_state", sys.argv[1])
reporter = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True  # no __pycache__ in hooks/lib: setup.sh copies it whole
spec.loader.exec_module(reporter)

COUNT, SEED = 3000, 20260925
K = "/x/.codex/hooks.json:pre_tool_use:0:0"
DECOY = "/x/.codex/hooks.json:pre_tool_use:0:1"
STALE = "/x/.codex/hooks.json:pre_tool_use:0:7"
TRICKY = [
    '"plain"', "'lit'", '"a # b"', '"x = y"', '"[not.a.header]"', '"esc \\" q"',
    '"""ml\nenabled = false\n"""', "'''ml\n[features]\ntrusted_hash = \"x\"\n'''",
    '"""a \\""" b"""', '"""\n"""', "'''\n'''", '""""a""""', "''''a''''",
    '[\n  ["a"],\n  "]",\n]', "[1, [2, 3]]", '{ a = 1, b = "}" }',
    '[\n  { x = "enabled = false" },\n]', '"""\n[hooks.state."' + K + '"]\n"""',
    "12", "true", "1979-05-27T07:32:00Z", "[ ]", "{}",
]
COMMENTS = ["", " # note", " # enabled = false", ' # trusted_hash = "sha256:zz"',
            " # [features]", " # \"q\" 'x' }", " #"]
rng = random.Random(SEED)


def ws():
    return rng.choice(["", " ", "  ", "\t", " \t "])


def spell(name):
    c = rng.random()
    if c < 0.55:
        return name
    if c < 0.85:
        return rng.choice(['"%s"', "'%s'"]) % name
    i = rng.randrange(len(name))
    return '"' + name[:i] + "\\u%04x" % ord(name[i]) + name[i + 1:] + '"'


def fields():
    out = [(n, v) for n, v in (
        ("enabled", rng.choice([None, None, "true", "false", "false", '"false"', "0"])),
        ("trusted_hash", rng.choice([None, '"sha256:x"', '"sha256:x"', "'sha256:x'",
                                     '"""sha256:x"""', "1"])),
    ) if v]
    rng.shuffle(out)
    return out


def noise():
    return spell(rng.choice(["note", "tags", "x-y", "meta"])) + ws() + "=" + ws() \
        + rng.choice(TRICKY) + rng.choice(COMMENTS)


def body(prefix):
    lines = [rng.choice(["", "  ", "\t"]) + prefix + spell(name) + ws() + "=" + ws() + value
             + rng.choice(COMMENTS) for name, value in fields()]
    for _ in range(rng.randrange(3)):
        lines.insert(rng.randrange(len(lines) + 1),
                     rng.choice(["", "# c", "  # enabled = false", noise() if not prefix else ""]))
    return lines


def entry(key):
    q = rng.choice(['"%s"', "'%s'"]) % key
    style = rng.choice(["header", "header", "header", "state-dotted", "hooks-dotted", "inline"])
    if style == "header":
        return [rng.choice([
            f"[hooks.state.{q}]", f"[ hooks . state . {q} ]", f'["hooks"."state".{q}]',
            f"[hooks.'state'.{q}]  # c", f"[hooks.state.{q}] # [x]",
        ])] + body("")
    if style == "state-dotted":
        return ["[hooks.state]"] + body(q + ".")
    if style == "hooks-dotted":
        return ["[hooks]"] + body("state." + q + ".")
    items = ", ".join(f"{spell(n)}{ws()}={ws()}{v}" for n, v in fields() if "\n" not in v)
    return ["[hooks.state]", f"{q} = {{ {items} }}" + rng.choice(COMMENTS)]


def config():
    parts = ["[features]", noise()] if rng.random() < 0.3 else []
    parts += entry(DECOY) if rng.random() < 0.3 else []
    parts += entry(K)
    if rng.random() < 0.15:
        parts += [f'[hooks.state."{STALE}"]', rng.choice(
            ['enabled = "no"', "trusted_hash = 7", 'trusted_hash = "sha256:s"', "enabled = false"])]
    parts += ["[tui]", noise()] if rng.random() < 0.3 else []
    text = "\n".join(parts) + rng.choice(["\n", ""])
    text = text.replace("\n", "\r\n") if rng.random() < 0.15 else text
    return ("﻿" + text) if rng.random() < 0.05 else text


def wrong_type(value):
    if not isinstance(value, dict):
        return True
    enabled, trusted_hash = value.get("enabled"), value.get("trusted_hash")
    return (enabled is not None and not isinstance(enabled, bool)) or (
        trusted_hash is not None and not isinstance(trusted_hash, str))


def reference(text):
    try:
        data = tomllib.loads(text[1:] if text.startswith("﻿") else text)
    except tomllib.TOMLDecodeError:
        return None
    hooks = data.get("hooks")
    state = hooks.get("state") if isinstance(hooks, dict) else None
    state = state if isinstance(state, dict) else {}
    if any(wrong_type(value) for value in state.values()):
        return "rejects"
    found = [value for key, value in state.items() if key.strip() == K]
    if not found:
        return "skips"
    enabled, trusted_hash = found[0].get("enabled"), found[0].get("trusted_hash")
    return "skips" if enabled is False or trusted_hash is None else "runs"


def reported(path):
    state = reporter.trust_state(path).get("pre_tool_use:0:0", "absent")
    if state in reporter.ACTIVE:
        return "runs"
    return "rejects" if state == "invalid" else "skips"


def main():
    tally = {"compared": 0, "agree": 0, "other reason": 0}
    kinds = {"runs": 0, "skips": 0, "rejects": 0}
    failures = []
    handle, path = tempfile.mkstemp(suffix=".toml")
    os.close(handle)
    try:
        for _ in range(COUNT):
            text = config()
            want = reference(text)
            if want is None:
                continue
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            tally["compared"] += 1
            kinds[want] += 1
            try:
                got = reported(path)
            except Exception as error:  # main() would turn this into silence
                failures.append(("crash", want, f"{type(error).__name__}: {error}", text))
                continue
            if got == want:
                tally["agree"] += 1
            elif got == "runs":
                failures.append(("SILENT: Codex does not run the hook", want, got, text))
            elif want == "runs":
                failures.append(("false alarm: Codex runs the hook", want, got, text))
            else:
                tally["other reason"] += 1
    finally:
        os.unlink(path)

    for kind, want, got, text in failures[:5]:
        print(f"FAIL: {kind} (reference {want}, reporter {got})")
        print(f"  {text!r}")
    # A generator that stops producing some kind of config would pass on nothing.
    thin = [k for k, n in kinds.items() if n < COUNT // 20] + (
        ["compared"] if tally["compared"] < COUNT * 3 // 4 else [])
    for name in thin:
        print(f"FAIL: too few '{name}' cases to mean anything: {kinds.get(name, tally['compared'])}")
    if not failures and not thin:
        print(f"PASS: {tally['compared']} of {COUNT} generated configs compared (seed {SEED}): "
              f"no silent miss, no false alarm, no exception; references {kinds}; "
              f"{tally['other reason']} reported under another reason")
    print(f"--- {0 if failures or thin else 1} passed, {len(failures) + len(thin)} failed ---")
    return 1 if failures or thin else 0


sys.exit(main())
PY
