#!/usr/bin/env bash
# T5 link tests: both values printed on failure (runbook.md rule B)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AIDD_LEDGER_SOURCE=test  # T9-2: ledger rows from test harness are source=test

python3 - "$ROOT" <<'PY'
import hashlib, json, os, re, sys
from pathlib import Path

ROOT = Path(sys.argv[1])
PASS = FAIL = 0

def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"PASS: {msg}")

def bad(msg: str, detail: str) -> None:
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")
    print(f"  {detail}")

repo = sorted(p.name for p in (ROOT / "hooks").glob("*.sh"))
deploy_dir = Path.home() / ".claude" / "hooks"
dep = sorted(p.name for p in deploy_dir.glob("*.sh")) if deploy_dir.is_dir() else []
# Local deploy pair: skip when no machine deploy (CI runners).
if not dep:
    ok("pair1 skipped (no local deploy hooks; CI/local-without-setup)")
elif repo == dep:
    ok("pair1 repo_hooks == deployed_hooks")
else:
    bad(
        "pair1 repo_hooks != deployed_hooks",
        f"repo={repo} deployed={dep}",
    )

settings_path = Path.home() / ".claude" / "settings.json"
if settings_path.is_file():
    s = json.loads(settings_path.read_text())
    registered = set()
    for _ev, ms in s.get("hooks", {}).items():
        for m in ms:
            for h in m.get("hooks", []):
                for part in re.findall(r"[\w./-]+\.sh", h.get("command", "")):
                    registered.add(os.path.basename(part))
    intentional = {"aidd-h3-evidence-check.sh"}
    missing = registered - set(repo) - intentional
    if not missing:
        ok("pair2 settings basenames ⊆ repo hooks (+intentional CLI)")
    else:
        bad(
            "pair2 settings basenames not in repo",
            f"settings={sorted(registered)} repo={repo} missing={sorted(missing)}",
        )

canon = ROOT / "docs" / "CANONICAL-STATE.md"
repo_settings = ROOT / "settings.json"
# Prefer repo settings.json so CI links declaration to SSOT (not machine deploy).
settings_for_pair5 = repo_settings if repo_settings.is_file() else settings_path
if canon.is_file() and settings_for_pair5.is_file():
    text = canon.read_text()
    m = re.search(
        r"Registered hooks in `settings\.json`\s*\|\s*\*\*(\d+)\*\*",
        text,
    )
    declared = int(m.group(1)) if m else None
    s = json.loads(settings_for_pair5.read_text())
    actual = sum(
        len(m.get("hooks", [])) for ms in s.get("hooks", {}).values() for m in ms
    )
    if declared == actual:
        ok(f"pair5 CANONICAL declared={declared} settings={actual} source={settings_for_pair5.name}")
    else:
        bad(
            "pair5 CANONICAL vs settings mismatch",
            f"declared={declared} settings={actual} source={settings_for_pair5}",
        )

wf = ROOT / ".github" / "workflows" / "h5-admission.yml"
if wf.is_file() and "h5-admission" in wf.read_text():
    ok("pair4 workflow file present with h5-admission")
else:
    bad("pair4 workflow missing", f"path={wf} exists={wf.is_file()}")

unused = ROOT / "hooks" / "_unused"
if unused.is_dir() and dep:
    bad_names = [
        f.name
        for f in unused.glob("*.sh")
        if (deploy_dir / f.name).is_file()
    ]
    if not bad_names:
        ok("pair6 no _unused basenames deployed")
    else:
        bad("pair6 retired hooks still deployed", f"deployed_retired={bad_names}")
elif unused.is_dir():
    ok("pair6 skipped (no local deploy)")

# ---- T7-3: 4-agent pairs (facts.yaml ids must all be exercised) ----
# Local-only pairs: skip when the target machine files are absent (CI-safe).
home = Path.home()

# pair7: codex hooks.json registrations ↔ deployed scripts
cj = home / ".codex" / "hooks.json"
if not cj.is_file():
    ok("pair7 codex hooks.json skipped (no Codex install)")
else:
    reg = json.loads(cj.read_text())
    cmds = [
        h.get("command", "")
        for ms in reg.get("hooks", {}).values()
        for m in ms
        for h in m.get("hooks", [])
    ]
    scripts = [
        c.split()[-1]
        for c in cmds
        if ".sh" in c
    ]
    missing_scripts = [s for s in scripts if not Path(s).expanduser().is_file()]
    if not missing_scripts:
        ok(f"pair7 codex hooks.json registrations exist on disk ({len(scripts)} registered)")
    else:
        bad(
            "pair7 codex hooks.json registered script missing",
            f"registered={scripts} missing={missing_scripts}",
        )

# pair8: codex AGENTS.md force-push protection ↔ default.rules forbidden rules
rules = home / ".codex" / "rules" / "default.rules"
if not rules.is_file():
    ok("pair8 codex execpolicy skipped (no default.rules)")
else:
    rule_text = rules.read_text()
    ops = [
        ('["git", "push", "--force"]', "force-push"),
        ('["git", "push", "origin", "main"]', "direct push main"),
        ('["git", "push", "origin", "master"]', "direct push master"),
        ('["git", "push", "origin", "develop"]', "direct push develop"),
        ('["git", "push", "--mirror"]', "mirror push"),
    ]
    absent = [label for pat, label in ops if f'prefix_rule(pattern={pat}, decision="forbidden")' not in rule_text]
    if not absent:
        ok("pair8 codex execpolicy covers AGENTS.md force-push/direct-push declaration")
    else:
        bad(
            "pair8 codex execpolicy missing forbidden rules",
            f"declared_in_AGENTS=force-push+direct-push missing_in_rules={absent}",
        )

# pair9: cursor guard hook ↔ its ledger (hook exists ⇒ ledger exists)
cg = home / ".cursor" / "hooks" / "git-guard.sh"
cl = home / ".cursor" / "hooks" / "guard-ledger.jsonl"
if not cg.is_file():
    ok("pair9 cursor guard hook skipped (no Cursor hook)")
elif cl.is_file():
    ok("pair9 cursor guard hook + ledger present")
else:
    bad(
        "pair9 cursor guard hook without ledger",
        f"hook={cg} ledger={cl} exists=False",
    )

# pair10: opencode team.ts blanket allow must be 0 (comments excluded)
oc_team = home / "Developer" / "opencode" / "packages" / "guardrails" / "profile" / "plugins" / "team.ts"
if not oc_team.is_file():
    ok("pair10 opencode team.ts skipped (no opencode checkout)")
else:
    text = oc_team.read_text()
    # count actual rule lines, excluding comment/doc lines
    blanket = [
        line.strip()
        for line in text.splitlines()
        if re.search(r'permission:\s*"\*",\s*pattern:\s*"\*",\s*action:\s*"allow"', line)
        and not line.lstrip().startswith(("*", "//", "/*", " *"))
    ]
    if not blanket:
        ok("pair10 opencode team.ts has zero blanket-allow rules")
    else:
        bad(
            "pair10 opencode team.ts blanket allow present",
            f"declared=0 actual={blanket}",
        )

# pair11: version-controlled Codex hook source ↔ deployed hook MD5
codex_source = ROOT / "hooks" / "codex" / "protect-branches-codex.sh"
codex_deployed = Path(
    os.environ.get(
        "AIDD_CODEX_HOOK_DEPLOYED",
        str(home / ".codex" / "hooks" / "protect-branches-codex.sh"),
    )
).expanduser()
if not codex_deployed.is_file():
    ok("pair11 Codex deployed hook skipped (no local deploy)")
elif not codex_source.is_file():
    bad(
        "pair11 Codex repo source missing",
        f"declaration={codex_source} enforcement={codex_deployed}",
    )
else:
    declaration_md5 = hashlib.md5(codex_source.read_bytes()).hexdigest()
    enforcement_md5 = hashlib.md5(codex_deployed.read_bytes()).hexdigest()
    if declaration_md5 == enforcement_md5:
        ok(
            "pair11 Codex hook MD5 match "
            f"declaration={declaration_md5} enforcement={enforcement_md5}"
        )
    else:
        bad(
            "pair11 Codex hook MD5 mismatch",
            f"declaration={declaration_md5} enforcement={enforcement_md5}",
        )

print(f"--- {PASS} passed, {FAIL} failed ---")
sys.exit(0 if FAIL == 0 else 1)
PY
