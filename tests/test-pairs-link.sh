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
SKIPPED: list[str] = []

def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"PASS: {msg}")

def skip(msg: str) -> None:
    """照合できなかった pair。PASS に数えない（#349）。

    これらは repo 正本 ↔ **配備先**を比べる pair であり、CI には配備先が存在しない。
    CI で fail させるのは誤りなので exit には影響させない。しかし PASS に混ぜると
    「15 の対が照合された」と読めてしまい、CI では実際には 5 しか照合していない。
    検査していないのに緑、という #120 と同じクラスの欠陥になる。
    """
    SKIPPED.append(msg)
    print(f"SKIP: {msg}")

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
    skip("pair1 skipped (no local deploy hooks; CI/local-without-setup)")
elif repo == dep:
    ok("pair1 repo_hooks == deployed_hooks")
else:
    bad(
        "pair1 repo_hooks != deployed_hooks",
        f"repo={repo} deployed={dep}",
    )

settings_path = Path.home() / ".claude" / "settings.json"
# else が無いと、配備先が無い環境で pair2 は PASS/SKIP/FAIL のどれも出さず
# **無言で消える**（#351）。skip 誤計上より重い: skip は少なくとも行が出る。
if not settings_path.is_file():
    skip("pair2 skipped (no local deploy settings.json)")
else:
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
if not (canon.is_file() and settings_for_pair5.is_file()):
    # ここは配備状態ではなく **repo の**ファイル。欠けていたら skip ではなく欠陥である。
    # pair13 の "source file missing" と同じ扱いにそろえる（#351 受入基準 6）。
    bad(
        "pair5 source file missing",
        f"declaration={canon} exists={canon.is_file()} "
        f"enforcement={settings_for_pair5} exists={settings_for_pair5.is_file()}",
    )
else:
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
    skip("pair6 skipped (no local deploy)")

# ---- T7-3: 4-agent pairs (facts.yaml ids must all be exercised) ----
# Local-only pairs: skip when the target machine files are absent (CI-safe).
home = Path.home()

# pair7: codex hooks.json registrations ↔ deployed scripts
cj = home / ".codex" / "hooks.json"
if not cj.is_file():
    skip("pair7 codex hooks.json skipped (no Codex install)")
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
    skip("pair8 codex execpolicy skipped (no default.rules)")
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
    skip("pair9 cursor guard hook skipped (no Cursor hook)")
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
    skip("pair10 opencode team.ts skipped (no opencode checkout)")
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
    skip("pair11 Codex deployed hook skipped (no local deploy)")
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

# pair12: version-controlled Cursor hook source ↔ deployed hook MD5
cursor_source = ROOT / "hooks" / "cursor" / "git-guard.sh"
cursor_deployed = Path(
    os.environ.get(
        "AIDD_CURSOR_HOOK_DEPLOYED",
        str(home / ".cursor" / "hooks" / "git-guard.sh"),
    )
).expanduser()
if not cursor_deployed.is_file():
    skip("pair12 Cursor deployed hook skipped (no local deploy)")
elif not cursor_source.is_file():
    bad(
        "pair12 Cursor repo source missing",
        f"declaration={cursor_source} enforcement={cursor_deployed}",
    )
else:
    declaration_md5 = hashlib.md5(cursor_source.read_bytes()).hexdigest()
    enforcement_md5 = hashlib.md5(cursor_deployed.read_bytes()).hexdigest()
    if declaration_md5 == enforcement_md5:
        ok(
            "pair12 Cursor hook MD5 match "
            f"declaration={declaration_md5} enforcement={enforcement_md5}"
        )
    else:
        bad(
            "pair12 Cursor hook MD5 mismatch",
            f"declaration={declaration_md5} enforcement={enforcement_md5}",
        )

# pair13: rules/hook-deployment.md 正本 pin ↔ docs/CANONICAL-STATE.md declared count
# 2026-09-01: the rule file pinned "18 登録" while CANONICAL-STATE declared 20.
# pair5 links CANONICAL↔settings.json, so nothing caught the rule file drifting.
# Both sides are declarations; that is exactly why a machine link is required
# (runbook.md 宣言と実体の二重管理 rule B — a "keep in sync" comment is not a fix).
rules_pin = ROOT / "rules" / "hook-deployment.md"
if not (rules_pin.is_file() and canon.is_file()):
    bad(
        "pair13 source file missing",
        f"declaration={rules_pin} exists={rules_pin.is_file()} "
        f"enforcement={canon} exists={canon.is_file()}",
    )
else:
    m_rule = re.search(r"`docs/CANONICAL-STATE\.md`\D*(\d+)\s*登録", rules_pin.read_text())
    m_canon = re.search(
        r"Registered hooks in `settings\.json`\s*\|\s*\*\*(\d+)\*\*", canon.read_text()
    )
    rule_n = int(m_rule.group(1)) if m_rule else None
    canon_n = int(m_canon.group(1)) if m_canon else None
    if rule_n is None or canon_n is None:
        bad(
            "pair13 could not parse a side",
            f"declaration(rules/hook-deployment.md)={rule_n} "
            f"enforcement(docs/CANONICAL-STATE.md)={canon_n}",
        )
    elif rule_n == canon_n:
        ok(f"pair13 rules pin == CANONICAL declared (both {rule_n})")
    else:
        bad(
            "pair13 rules pin != CANONICAL declared",
            f"rules/hook-deployment.md={rule_n} docs/CANONICAL-STATE.md={canon_n}",
        )

# pair14: delegation contract stop conditions ↔ H1 runtime block enforcement.
# Declaration = skills/handover/SKILL.md 委任契約 欄1-3.
# Enforcement = hooks/codex/h1-stall-runtime.sh env-overridable defaults.
# Every declared stop condition must have a machine strong-point, and 欄1's
# "既定 10" is fixed on both sides so its number is compared directly.
# Known unreconciled divergences (欄2 2h vs 45min, 欄3 $10 vs $5) are recorded
# in facts.yaml and deliberately NOT asserted here — see that note.
contract = ROOT / "skills" / "handover" / "SKILL.md"
h1_hook = ROOT / "hooks" / "codex" / "h1-stall-runtime.sh"
if not contract.is_file() or not h1_hook.is_file():
    bad(
        "pair14 H1 contract/enforcement file missing",
        f"declaration={contract} (exists={contract.is_file()}) "
        f"enforcement={h1_hook} (exists={h1_hook.is_file()})",
    )
else:
    contract_text = contract.read_text(encoding="utf-8")
    hook_text = h1_hook.read_text(encoding="utf-8")
    fields = [
        ("停止条件と最大反復", "CODEX_H1_MAX_ITERATIONS"),
        ("報告間隔 / 無進捗タイムアウト", "CODEX_H1_NO_PROGRESS_SEC"),
        ("課金上限", "CODEX_H1_BUDGET_USD"),
    ]
    unenforced = [
        (label, var)
        for label, var in fields
        if label not in contract_text or f'env_num("{var}"' not in hook_text
    ]
    # 2026-09-01: 欄2/欄3 の宣言 (2h / $10) は H1 spec と実装 (45min / $5) と食い違って
    # いたため、欄1 のみ数値照合していた。正本を H1 spec 側に寄せる決定
    # (aidd-governance ADR-005) により、3 欄すべてを数値照合へ広げる。
    # 宣言の単位は分・ドル、強制側は秒・ドル。単位を揃えてから比べる。
    numeric = [
        ("欄1 max_iterations", r"停止条件と最大反復:\s*既定\s*(\d+)",
         r'env_num\("CODEX_H1_MAX_ITERATIONS",\s*([0-9.]+)\)', 1),
        ("欄2 no_progress_sec", r"無進捗タイムアウト:\s*既定\s*\d+\s*分\s*/\s*(\d+)\s*分",
         r'env_num\("CODEX_H1_NO_PROGRESS_SEC",\s*([0-9.]+)\)', 60),
        ("欄3 budget_usd", r"課金上限:\s*\$<[^>]*既定\s*\$(\d+(?:\.\d+)?)>",
         r'env_num\("CODEX_H1_BUDGET_USD",\s*([0-9.]+)\)', 1),
    ]
    mismatches = []
    for label, dpat, epat, scale in numeric:
        dm = re.search(dpat, contract_text)
        em = re.search(epat, hook_text)
        dv = float(dm.group(1)) * scale if dm else None
        ev = float(em.group(1)) if em else None
        if dv is None or ev is None or dv != ev:
            mismatches.append(
                f"{label}: declaration={dm.group(1) if dm else 'MISSING'}"
                f"(={dv}) enforcement={em.group(1) if em else 'MISSING'}(={ev})"
            )
    if unenforced:
        bad(
            "pair14 delegation contract stop condition without H1 enforcement",
            f"declaration={contract} enforcement={h1_hook} "
            f"unenforced={[f'{a}->{b}' for a, b in unenforced]}",
        )
    elif mismatches:
        bad(
            "pair14 contract/enforcement numeric mismatch",
            f"declaration={contract}#委任契約欄1-3 "
            f"enforcement={h1_hook} :: " + " | ".join(mismatches),
        )
    else:
        ok("pair14 delegation contract 欄1-3 match H1 enforcement numerically "
           "(10 iterations / 2700s / $5.0)")

# pair15: Codex hooks.json registration ↔ config.toml trust state.
# 2026-09-01: protect-branches-codex.sh was deployed, registered, and MD5-matched
# with its repo source, yet fired ZERO times for 19 days — config.toml carried
# `enabled = false` for its position. pair7 (registration↔file exists) and pair11
# (source↔deployed MD5) both PASSED throughout, because neither looks at trust.
# Codex keys trust by POSITION ("<event>:<matcher>:<hook>"), so inserting a hook
# also invalidates the entry that used to occupy that index.
# A registered hook with no enabled trust entry is skipped SILENTLY — no error,
# no log line — which is why this needs a machine link rather than a habit.
codex_hooks_json = home / ".codex" / "hooks.json"
codex_config = home / ".codex" / "config.toml"
if not codex_hooks_json.is_file() or not codex_config.is_file():
    skip("pair15 codex trust state skipped (no Codex install)")
else:
    event_key = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use"}
    registered = {}
    for ev, ms in json.loads(codex_hooks_json.read_text()).get("hooks", {}).items():
        key = event_key.get(ev, ev.lower())
        for mi, m in enumerate(ms):
            for hi, h in enumerate(m.get("hooks", [])):
                script = os.path.basename(h.get("command", "").split()[-1]) if h.get("command") else "?"
                registered[f"{key}:{mi}:{hi}"] = script

    toml_text = codex_config.read_text()
    trust = {}
    for m in re.finditer(
        r'\[hooks\.state\."[^"]*:([a-z_]+:\d+:\d+)"\]\n((?:[a-z_]+ = [^\n]*\n)*)',
        toml_text,
    ):
        body = m.group(2)
        if re.search(r"^enabled = false", body, re.M):
            state = "disabled"
        elif re.search(r"^enabled = true", body, re.M):
            state = "enabled"
        else:
            state = "unset"   # Codex defaults to enabled, but say so explicitly
        trust[m.group(1)] = state

    broken = []
    for idx, script in sorted(registered.items()):
        st = trust.get(idx, "absent")
        if st == "disabled":
            broken.append(f"{idx}({script}) trust=disabled -> hook is skipped silently")
        elif st == "absent":
            broken.append(f"{idx}({script}) trust=absent -> not yet trusted, hook is skipped silently")
    if not broken:
        summary = ", ".join(f"{i}={trust.get(i, 'absent')}" for i in sorted(registered))
        ok(f"pair15 every registered Codex hook has an active trust entry ({summary})")
    else:
        bad(
            "pair15 Codex hook registered without active trust",
            f"declaration={codex_hooks_json} registered={sorted(registered.items())} "
            f"enforcement={codex_config} trust={trust} broken={broken}",
        )

# pair17: aidd-governance の payload 正本 ↔ 配備先のマーカーブロック（aidd-governance#82）
# payload/README.md は「payload と適用先を個別に手編集せず、payload を正として同期検査を
# 行う」と宣言していたが、その同期検査は存在しなかった。宣言だけあって強制が無い定型。
# pair11/12 の MD5 全体一致は使えない。配備先（~/.codex/rules/default.rules 等）は
# payload 以外の行も正当に持つため、**包含**の照合になる。
# 方式: 開きマーカーへ payload の sha256 を埋め、ブロック内側のバイト列の sha256 と比べる。
#   - 配備先を手編集 → 内側の hash が変わる → red（marker の記録値と want が一致するので
#     「手編集」と診断できる）
#   - payload を変更して未適用 → want が変わる → red（marker の記録値が古いので「未適用」）
#   - マーカーを消す → block-missing → red
# 正規化は「末尾改行を 1 個に揃える」だけ。内容の 1 バイト変更は必ず hash に出る。
gov = Path(os.environ.get("AIDD_GOV_ROOT", str(home / "Developer" / "aidd-governance")))
manifest = gov / "design" / "ops" / "payloads" / "manifest.tsv"
if not manifest.is_file():
    skip("pair17 payload manifest skipped (aidd-governance not present)")
else:
    def _norm(t: str) -> str:
        return t.rstrip("\n") + "\n"

    problems = []
    checked = 0
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3:
            problems.append(f"manifest row is not 3 columns: {raw!r}")
            continue
        name, target, style = (c.strip() for c in parts)
        src = gov / "design" / "ops" / "payloads" / name
        dest = Path(target.replace("$HOME", str(home)))
        if not src.is_file():
            problems.append(f"{name}: payload missing at {src}")
            continue
        if not dest.is_file():
            # 配備先が無い機械では照合対象が無い（pair11/12 の「no local deploy」と同じ）
            continue
        if style == "hash":
            pre, suf = f"# >>> aidd-payload: {name} sha256=", " >>>"
            close_m = f"# <<< aidd-payload: {name} <<<"
        elif style == "html":
            pre, suf = f"<!-- >>> aidd-payload: {name} sha256=", " >>> -->"
            close_m = f"<!-- <<< aidd-payload: {name} <<< -->"
        else:
            problems.append(f"{name}: unknown marker_style {style!r}")
            continue
        want = hashlib.sha256(_norm(src.read_text(encoding="utf-8")).encode()).hexdigest()
        text = dest.read_text(encoding="utf-8")
        m = re.search(
            r"^" + re.escape(pre) + r"([0-9a-f]{64})" + re.escape(suf)
            + r"\n([\s\S]*?)^" + re.escape(close_m) + r"\n?",
            text,
            re.M,
        )
        checked += 1
        if m is None:
            problems.append(
                f"{name}: block-missing | declaration={src} sha256:{want} "
                f"enforcement={dest} (no marker block)"
            )
            continue
        got = hashlib.sha256(_norm(m.group(2)).encode()).hexdigest()
        if got != want:
            reason = ("deployed block hand-edited" if m.group(1) == want
                      else "payload changed since last apply")
            problems.append(
                f"{name}: {reason} | declaration({src})=sha256:{want} "
                f"enforcement({dest})=sha256:{got} marker_records={m.group(1)}"
            )
    if problems:
        bad("pair17 payload SSOT != deployed block", " ; ".join(problems))
    elif checked == 0:
        skip("pair17 payload blocks skipped (no deployed target on this machine)")
    else:
        ok(f"pair17 payload SSOT == deployed block ({checked} payload(s) verified)")

# pair16: facts.yaml 登録簿 ↔ test-pairs-link.sh が実装している pair 群。
# aidd-governance#97 —「二重管理が系統的に散在すると知りながら能動的に掃かず、
# CD の失敗を 1 件ずつ受動的に発見した」。同じ受動性が登録簿自身にも起きていた。
# facts.yaml の冒頭は「facts.yaml ids must all be exercised」と宣言していたが、
# それを機械照合するものが無く、2026-09-02 実測で実装 14 に対し登録 11 だった
# （pair2 / pair4 / pair6 が未登録）。宣言だけあって強制が無い、この repo の定型。
# 両方向を見る: 実装された pairN は必ず登録され、登録エントリは必ず pair 欄を持つ。
facts = ROOT / "facts.yaml"
selftest = ROOT / "tests" / "test-pairs-link.sh"
if not (facts.is_file() and selftest.is_file()):
    bad(
        "pair16 source file missing",
        f"declaration={facts} exists={facts.is_file()} "
        f"enforcement={selftest} exists={selftest.is_file()}",
    )
else:
    facts_text = facts.read_text(encoding="utf-8")
    # 実装側: ok()/bad() のメッセージ文字列の先頭に現れる pairN だけを数える。
    # コメント中の言及（`# pair13: ...`）は引用符が前に無いので拾わない。
    implemented = {
        f"pair{n}"
        for n in re.findall(r"[\"']pair(\d+)\b", selftest.read_text(encoding="utf-8"))
    }
    entries = re.findall(r"^  - id: (\S+)$", facts_text, re.M)
    registered = re.findall(r"^    pair: (\S+)$", facts_text, re.M)
    unregistered = sorted(implemented - set(registered))
    no_field = len(entries) - len(registered)
    dangling = sorted(p for p in registered if p != "none" and p not in implemented)
    if unregistered or no_field or dangling:
        bad(
            "pair16 registry/implementation drift",
            f"declaration(facts.yaml)={sorted(set(registered))} entries={len(entries)} "
            f"pair_fields={len(registered)} | "
            f"enforcement(tests/test-pairs-link.sh)={sorted(implemented)} | "
            f"implemented_but_unregistered={unregistered} "
            f"entries_missing_pair_field={no_field} "
            f"registered_but_unimplemented={dangling}",
        )
    else:
        ok(
            f"pair16 facts.yaml registry == implemented pairs "
            f"({len(implemented)} implemented, {len(entries)} entries, "
            f"{registered.count('none')} declared none)"
        )

# pair18: settings.json が登録する検査器 ↔ 自己完結した陰性テスト
# aidd-governance#97 項目3 / #98 項目3 —「既知の欠陥を注入して red を実測して
# いない検査器は、検査器として数えない」。
#
# ---- 分母をなぜ「登録 23 本」にするか（block 権限を持つものだけに絞らない）----
#
# (1) #98 が挙げた false GREEN は、block しない検査器で起きた。
#     3 例目は `gcloud --help` を読む**計測器**であって block 装置ではない。
#     「検査器自身が false GREEN を出した」の実例がまさに非 block 系である。
#     block 権限で絞ると、issue が名指しした欠陥クラスが分母から落ちる。
#
# (2) 今回補った 4 本のうち notify-agent-failure.sh は block しない（分類して
#     親へ返すだけ）。block 限定の分母なら最初から対象外になり、
#     「分類分岐が結論を作っているか未検証」は残ったままだった。
#
# (3) 他の線引きは手で維持する分類表を要求する。「block 権限を持つか」は
#     settings.json からは読めず、各 hook の exit 2 経路を読む必要がある。
#     分類表を置けば、それ自体が宣言と実体の二重管理になる（本 repo が
#     繰り返し踏んでいる形）。settings.json の登録は**機械的に導出できる
#     唯一の線**であり、かつ「実際に発火する」と一致する。
#
# ---- 分母を広く取っても恒久 red にはならない（2026-09-03 develop 実測: PASS）----
#
# red になるのは次の 3 条件だけである。分母の広さは red の条件ではない。
#   - 新規登録された検査器に自己完結した陰性テストが無い（h5 が通してしまう形）
#   - 既存の陰性テストを消す / env 差し込み形へ戻す（回帰）
#   - baseline にあるものが担保済みになったのに baseline から消していない（腐敗）
# 分母が決めているのは**北極星（担保率）の天井**であって発火条件ではない。
#
# 狭い分母にすると、未担保 13 本が**記録から消える**。恒久 red を避ける代償に
# 未担保の存在自体を見えなくするのは、#97 が問うている受動性そのものである。
# 13 本の内訳（後続の判断材料。分類は 2026-09-03 実測）:
#   - テストが 1 本も無い 9 本: auto-init-permissions / auto-update-plugins /
#     dns-self-heal / enforce-branch-workflow / post-deploy-verify /
#     post-lint-format / pre-compact-context-save / tool-failure-recovery /
#     verify-agent-output
#   - テストはあるが自己完結でない 4 本: aidd-h3-evidence-stop（t92 は
#     lib/aidd-ledger.sh の source 列を見るだけ）/ auto-commit-worktree-changes /
#     enforce-hook-deploy-after-merge / validate-provider-env
#
# なぜ h5-admission では足りないか（2026-09-03 実測。作るか作らないかの分岐点）:
#   scripts/h5-admission-check.sh の has_marker() は
#   `H5-NEGATIVE:` の後ろに 9 文字以上あるかを PR 本文で見るだけである。
#   実測 3 本:
#     A 新規 hook + "HOOK_DIR=/tmp/unfixed bash ... -> 6 failed" → exit 0 (PASS)
#     B 新規 hook + テストファイルを 1 つも足さず散文だけ        → exit 0 (PASS)
#     C 新規 hook + マーカー無し（対照）                          → exit 1 (FAIL)
#   C が落ちるので h5 は壊れていない。しかし A/B が通る以上、h5 は
#   **PR 単位の宣言**を強制しているだけで、検査器単位で陰性テストが
#   存在するか・走るかは見ていない。したがって backfill は一度きりにならない。
#
# なぜ「外から env で差し込む」形を数えないか（実測）:
#   tests/test-issue-263-multi-repo-ctx.sh は壊れた版を
#   `git show origin/develop:hooks/git-push-guard.sh` で人が用意し
#   `HOOK_DIR=` で差し込む形だった。2 つの理由でその赤は存在しなかった:
#     1. .github/workflows/ci.yml は `bash tests/test-*.sh` としか書かず、
#        HOOK_DIR の出現は 0 件。CI は緑側しか走らせない。
#     2. origin/develop は**動く ref**。#263 の修正が着地した時点で
#        レシピは修正版を出すようになり、2026-09-03 実測で
#        「15 passed, 0 failed」= 赤が消えた。
#   「陰性テストがある」と「陰性テストが走っている」は別である。
#
# 判定軸: テストが**自分で**変異体を書き出し、**同じ実行の中で**それを走らせるか。
# 宣言側 = settings.json の登録（= 実際に発火する検査器）
# 強制側 = tests/*.sh の `# NEGATIVE-TEST-FOR: hooks/<name>.sh` と、その中身。
#
# ラチェット: 現在 未担保の集合を UNCOVERED_BASELINE に固定する。
#   - baseline に無い検査器が未担保になったら落ちる
#     （新設された検査器、または陰性テストを消した回帰）
#   - baseline にあるのに担保済みになったら落ちる（baseline を腐らせない）
# 割合は下げられない。北極星（担保率）は単調増加しかしない。
settings_repo = ROOT / "settings.json"
if not settings_repo.is_file():
    bad("pair18 source file missing", f"declaration={settings_repo} exists=False")
else:
    reg = set()
    for _ev, ms in json.loads(settings_repo.read_text(encoding="utf-8")).get("hooks", {}).items():
        for m in ms:
            for h in m.get("hooks", []):
                for part in re.findall(r"[\w./-]+\.sh", h.get("command", "")):
                    reg.add(f"hooks/{os.path.basename(part)}")

    # 強制側: マーカーを持ち、かつ**自己完結している**テストだけを数える。
    # 自己完結の構造条件（語ではなく構造で見る）:
    #   (a) 変異体をこのファイル自身が書き出す — 元を読んで別パスへ write する
    #   (b) 書き出した先の変数を、このファイル自身が実行する
    # (b) が無いと「変異体を作ったが走らせていない」を通してしまう。
    covered: dict[str, str] = {}
    not_self_contained: list[str] = []
    for t in sorted((ROOT / "tests").glob("test-*.sh")):
        text = t.read_text(encoding="utf-8", errors="replace")
        marks = re.findall(r"^#\s*NEGATIVE-TEST-FOR:\s*(\S+)\s*$", text, re.M)
        if not marks:
            continue
        # (a) 変異体の書き出し先に渡される変数（元を読んで別パスへ write する行）
        # (b) それとは別の行で、コマンドの引数として渡される変数
        written, executed = set(), set()
        for line in text.splitlines():
            is_write = ("python3 - " in line) or bool(re.search(r"\bmutate\s", line))
            if is_write:
                written.update(re.findall(r'"\$(\w+)"', line))
                continue
            # `cmd "$V"` の形。`$(...)` の内側も拾う。
            # `-f "$V"` のようなファイルテストは実行ではないので落とす
            # （不在の確認は「走らせた」証拠にならない）。
            for head, var in re.findall(r'([\w./-]+)\s+"\$(\w+)"', line):
                if not head.startswith("-"):
                    executed.add(var)
        self_contained = bool(written & executed)
        for h in marks:
            if self_contained:
                covered[h] = t.name
            else:
                not_self_contained.append(f"{h}<-{t.name}")

    # 宣言されたのに実体が無いマーカー（削除・改名の検出）
    dangling_marks = sorted(h for h in covered if not (ROOT / h).is_file())

    # 2026-09-03 実測の未担保集合。担保が付いたらこの行から消す（消し忘れも落ちる）。
    UNCOVERED_BASELINE = {
        "hooks/aidd-h3-evidence-stop.sh",
        "hooks/auto-commit-worktree-changes.sh",
        "hooks/auto-init-permissions.sh",
        "hooks/auto-update-plugins.sh",
        "hooks/dns-self-heal.sh",
        "hooks/enforce-branch-workflow.sh",
        "hooks/enforce-hook-deploy-after-merge.sh",
        "hooks/post-deploy-verify.sh",
        "hooks/post-lint-format.sh",
        "hooks/pre-compact-context-save.sh",
        "hooks/tool-failure-recovery.sh",
        "hooks/validate-provider-env.sh",
        "hooks/verify-agent-output.sh",
    }
    uncovered = reg - set(covered)
    regressed = sorted(uncovered - UNCOVERED_BASELINE)   # 新設 or 陰性テスト削除
    stale = sorted(UNCOVERED_BASELINE - uncovered)       # 担保済みなのに baseline に残存
    if regressed or stale or dangling_marks or not_self_contained:
        bad(
            "pair18 registered checkers without a self-contained negative test",
            f"declaration(settings.json)={len(reg)} registered | "
            f"enforcement(tests/*.sh NEGATIVE-TEST-FOR)={len(covered)} covered "
            f"({sorted(covered)}) | "
            f"newly_uncovered={regressed} "
            f"covered_but_still_in_baseline={stale} "
            f"marker_targets_missing={dangling_marks} "
            f"marked_but_not_self_contained={sorted(not_self_contained)}",
        )
    else:
        # 分子は **登録集合との積**で数える。covered には settings.json に
        # 登録されていない対象も入りうる（Codex hook は ~/.codex/hooks.json、
        # scripts/ の検査器はそもそも hook ではない）。それらを分子に足すと
        # 「N/23 registered」が登録以外を含んだ数になり、測った以上を主張する。
        # 担保があること自体は良いので、登録外は別枠で数えて見えるようにする。
        covered_registered = sorted(set(covered) & reg)
        covered_other = sorted(set(covered) - reg)
        ok(
            f"pair18 self-contained negative-test coverage "
            f"({len(covered_registered)}/{len(reg)} registered checkers; "
            f"{len(UNCOVERED_BASELINE)} declared uncovered; "
            f"{len(covered_other)} covered but not settings.json-registered)"
        )

# 3 値で出す。skipped は「照合できなかった」であって「通った」ではない。
print(f"--- {PASS} passed, {len(SKIPPED)} skipped, {FAIL} failed ---")
if SKIPPED:
    # skip の理由を 1 行ずつ常時出す。「なぜ CI では 5 本なのか」を毎回ログに残す
    # ためで、失敗時だけの診断ではない。
    print(f"--- skipped ({len(SKIPPED)}): machine-local pairs; this environment "
          f"has no deployed target to compare against ---")
    for m in SKIPPED:
        print(f"  SKIP: {m}")
# exit の意味は変えない（#349: CI を落とすのが目的ではない）。
sys.exit(0 if FAIL == 0 else 1)
PY
