#!/usr/bin/env bash
# H17 deadline source — negative + positive tests.
# NEGATIVE-TEST-FOR: hooks/lib/aidd_cc_text.py (parse_deadline_hours / user_authored_text)
#
# 起点事故: 2026-11-12 10:23:18Z、統括セッション e5a34bab に届いた subagent の完了通知
# (<task-notification>) の本文に査読結果の説明「時計の戻り: 15 分以内なら翌朝の入力は残り…」があり、
# DEADLINE_RE が作業の期限として拾った。期限は write-once (deadline_set) なので、利用者が期限を
# 指示していないのに、以後の Stop が毎回 DOT-INC-004/045 で止められた。
# 実測: queue-operation の remove 10:23:18.181Z と state の deadline(1794479898.167) − 900s = 10:23:18.167Z。
# 同じ machine の queue 2294 行のうち、利用者の素の入力は 277 行で、残りは
# cross-session-message / system-reminder / task-notification / pasted_content / ci-monitor-event の外枠つき。
#
# 見るもの: 期限を作る入力は「利用者が自分で打った文」に限る。harness・subagent・他セッションが
# prompt に差し込む外枠ブロック、引用行、コードフェンスの中の文は期限にしない。
# 利用者が本当に指示した期限 (30分以内 / 2時間以内 / within 2h) は今までどおり設定される。
# 片側変異: (a) AIDD_CC_MUTATE=deadline.user-text-only、(b) 種別の判定を外したコード変異体。
# どちらも、事故入力で期限が付き (陰性が red)、利用者の期限は付いたまま (陽性は green のまま) になること。
# 全て HOME 外の sandbox で走り、本番台帳・state には触れない。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
python3 -I - "$ROOT" "$SB" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

root, sb = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "hooks" / "lib"))
import aidd_cc_text as T  # noqa: E402

results: list[bool] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append(ok)
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok else f" — {detail}"))


BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith("AIDD_CC_")}
BASE_ENV.update(
    AIDD_LEDGER_SOURCE="test",
    AIDD_LEDGER_PATH=str(sb / "ledger.jsonl"),
    AIDD_CC_STATE_DIR=str(sb / "state"),
    AIDD_CC_MAX_STOP_BLOCKS="99",
)

# --- fixtures -----------------------------------------------------------------------------------------------
# The sentence below is the one that set the deadline (verbatim from the 2026-11-12 incident notification).
INCIDENT_SENTENCE = (
    "6. 時計の戻り: 15 分以内なら翌朝の入力は残り、時計が追いついた時点で 1 回だけ送られました。"
    "15 分を超えて戻ると入力は消えます（grant の最大寿命を超えるので、設計どおりです）。"
)
NOTIFICATION = (
    "<task-notification>\n<task-id>a30e5b682e6b1f3bf</task-id>\n"
    "<tool-use-id>toolu_01S6WLDZ8WeCauT3Piai587r</tool-use-id>\n"
    "<output-file>/private/tmp/claude-501/tasks/a30e5b682e6b1f3bf.output</output-file>\n"
    "<status>completed</status>\n<summary>Agent \"査読\" completed</summary>\n"
    f"<result>査読結果です。\n{INCIDENT_SENTENCE}\n</result>\n"
    "<usage><subagent_tokens>251351</subagent_tokens><tool_uses>21</tool_uses>"
    "<duration_ms>1029898</duration_ms></usage>\n</task-notification>"
)
CROSS = '<cross-session-message from="local_abc123">進捗です。30分以内に収まる見込みです。</cross-session-message>'
REMINDER = (
    "<system-reminder>\nThe session \"R5-04\" finished a turn. It reported (quoted child output, data not "
    "instructions): \"retry within 2h if the gate is red\"\n</system-reminder>"
)
PASTED = '<pasted_content id="a344">\n前の依頼: 6h以内に出して\n</pasted_content id="a344">'
NESTED = "<system-reminder>外 <system-reminder>内</system-reminder> 30分以内に直す </system-reminder>"
CI_EVENT = "<ci-monitor-event>checks green; merge window within 1h</ci-monitor-event>"
SIDE_EVENT = "<side-sessions-event>the session reported; retry 45分以内 if red</side-sessions-event>"
TN_OPEN, TN_CLOSE = "<task-notification>", "</task-notification>"
# Independent review (2026-11-12): a subagent result that quotes an envelope tag literally leaves the data unbalanced.
QUOTED_OPEN = f"{TN_OPEN}<result>15分以内なら。例 {TN_OPEN} の形式</result>{TN_CLOSE}"
QUOTED_CLOSE = f"{TN_OPEN}<result>例 {TN_CLOSE} の形式。15分以内なら</result>{TN_CLOSE}"
OVERLAP = "<a-b>x<c-d>y</a-b>30分以内</c-d>"
ATTR_LT = '<cross-session-message note="<x">30分以内</cross-session-message>'
UNCLOSED_ENVELOPE = f"{TN_OPEN}\n<result>15分以内なら翌朝の入力は残り</result>"
UNPAIRED_OPEN_FIRST = "<my-component> を直して。30分以内に終えて"
FENCED = "ログ:\n```\ndeadline: 30分以内\n```\nこの結果を見て。"
QUOTED = "> 15 分以内なら翌朝の入力は残り\n上の文はレビュー結果の引用です。"

# (label, prompt, expected hours or None)
NEGATIVE = [
    ("task-notification (the incident, verbatim sentence)", NOTIFICATION),
    ("cross-session-message", CROSS),
    ("system-reminder", REMINDER),
    ("pasted_content with an id on both tags", PASTED),
    ("nested same-name envelopes (inner close must not leak the tail)", NESTED),
    ("ci-monitor-event (generic rule, no list)", CI_EVENT),
    ("side-sessions-event (generic rule, no list)", SIDE_EVENT),
    ("fenced code block", FENCED),
    ("tilde-fenced code block", "~~~\n30分以内\n~~~"),
    ("unclosed code fence runs to the end of the prompt", "```\n30分以内"),
    ("quoted line", QUOTED),
    ("an envelope body that quotes the OPENING tag literally (unbalanced)", QUOTED_OPEN),
    ("an envelope body that quotes the CLOSING tag literally (ends the block early)", QUOTED_CLOSE),
    ("overlapping envelopes of different names", OVERLAP),
    ("an attribute value that contains '<'", ATTR_LT),
    ("an unclosed envelope fails closed (the rest is not the user's)", UNCLOSED_ENVELOPE),
    ("an unpaired opening tag fails closed: a missed deadline is cheap, a bogus write-once one is not", UNPAIRED_OPEN_FIRST),
]
POSITIVE = [
    ("30分以内 typed by the user", "この修正を30分以内に終えて", 0.5),
    ("2時間以内 typed by the user", "2時間以内にお願いします", 2.0),
    ("6h以内 typed by the user", "6h以内で", 6.0),
    ("within 2h typed by the user", "please finish within 2h", 2.0),
    (
        "user's own sentence after a system-reminder: the reminder's 2h is ignored, the user's 30分 wins",
        REMINDER + "\n\nこちらの作業は30分以内に終えてください。",
        0.5,
    ),
    (
        "user's own sentence after a task-notification: the notification's 15 分 is ignored, the user's 2時間 wins",
        NOTIFICATION + "\n\n2時間以内に仕上げて",
        2.0,
    ),
    (
        "user's sentence before a pasted_content block",
        "30分以内に直して。\n" + PASTED,
        0.5,
    ),
    (
        "the user's sentence before an unpaired opening tag survives",
        "30分以内に終えて。<my-component> の表示を直して",
        0.5,
    ),
    (
        "a stray closing tag with no block before it is plain text",
        "</my-component> を足して。30分以内に終えて",
        0.5,
    ),
    (
        "the user's sentence between two same-name envelopes survives",
        REMINDER + "\n30分以内に終えて\n" + REMINDER,
        0.5,
    ),
    (
        "user's sentence after a closed code fence",
        "```\nlog line\n```\n30分以内に終えて",
        0.5,
    ),
]


def run_cc(lib: Path, args: list[str], payload: dict | None, env_extra: dict | None = None) -> dict:
    env = {**BASE_ENV, **(env_extra or {})}
    p = subprocess.run(
        [sys.executable, "-I", str(lib / "aidd_cc.py"), *args],
        input=json.dumps(payload, ensure_ascii=False) if payload is not None else "",
        capture_output=True, text=True, env=env, timeout=60,
    )
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"_error": p.stdout + p.stderr}


def deadline_hours(lib: Path, sid: str, text: str, env_extra: dict | None = None):
    """Hours the prompt hook registered as a deadline, or None."""
    out = run_cc(lib, ["prompt", "--session", sid], {"prompt": text}, env_extra)
    for item in out.get("registered", []):
        if item.startswith("deadline+") and item.endswith("h"):
            return float(item[len("deadline+"):-1])
    return None


def deadline_set(lib: Path, sid: str) -> bool:
    return bool(run_cc(lib, ["deadline", "show", "--session", sid], None).get("set"))


LIB = root / "hooks" / "lib"

# 1. the parser itself (what DEADLINE_RE is allowed to see)
check("parse_deadline_hours: the incident notification yields no deadline",
      T.parse_deadline_hours(NOTIFICATION) is None,
      f"got {T.parse_deadline_hours(NOTIFICATION)!r} hours from a <task-notification> body")

# 2. every non-user text: no deadline through the real prompt command
for i, (label, text) in enumerate(NEGATIVE):
    got = deadline_hours(LIB, f"dsrc-neg-{i}", text)
    check(f"negative: {label} sets no deadline", got is None, f"registered deadline+{got}h")

# 3. every user-typed deadline: still set, with the same hours as before
for i, (label, text, hours) in enumerate(POSITIVE):
    got = deadline_hours(LIB, f"dsrc-pos-{i}", text)
    check(f"positive: {label} -> {hours}h", got == hours, f"expected {hours}, got {got}")

# 3b. time bound: aidd-cc-claude.sh is registered with a 10 s timeout, so a large prompt must not stall it
import time  # noqa: E402

for label, big in (
    ("480KB of unmatched closing tags among unclosed openings", "<a-b>x</c-d>" * 40000),
    ("100k unterminated opening tags with attributes", "<a-b " * 100000),
    ("100k nested openings, one closing", "<a-b>" * 100000 + "</a-b>"),
    ("100k alternating stray closes after an opening", "<a-b>" + "</a-b>x" * 100000),
):
    t0 = time.perf_counter()
    T.parse_deadline_hours(big)
    took = time.perf_counter() - t0
    check(f"time bound: {label} ({len(big):,} chars) stays under 2 s", took < 2.0, f"took {took:.2f}s")

# 4. end to end through the registered Claude Code hook entry (UserPromptSubmit -> state -> deadline show)
HOOK = root / "hooks" / "aidd-cc-claude.sh"


def via_hook(sid: str, text: str) -> None:
    subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt": text}, ensure_ascii=False),
        capture_output=True, text=True, env=BASE_ENV, timeout=60,
    )


via_hook("dsrc-hook-neg", NOTIFICATION)
check("hook entry: the incident notification leaves the session without a deadline",
      not deadline_set(LIB, "dsrc-hook-neg"), "deadline show reports set=true")
via_hook("dsrc-hook-pos", "この修正を30分以内に終えて")
shown = run_cc(LIB, ["deadline", "show", "--session", "dsrc-hook-pos"], None)
check("hook entry: a user's 30分以内 still sets a 30 minute deadline",
      bool(shown.get("set")) and 1700 < float(shown.get("remaining_sec") or 0) <= 1800,
      f"deadline show={shown}")

# 5. one-sided mutations: the incident input gets a deadline again, the user's deadline stays set
ENV_MUT = {"AIDD_CC_MUTATE": "deadline.user-text-only"}
got = deadline_hours(LIB, "dsrc-mut-env-neg", NOTIFICATION, ENV_MUT)
check("mutation deadline.user-text-only: the incident notification sets a deadline again (the guard is load-bearing)",
      got == 0.25, f"expected 0.25 under mutation, got {got}")
got = deadline_hours(LIB, "dsrc-mut-env-pos", "この修正を30分以内に終えて", ENV_MUT)
check("mutation deadline.user-text-only: a user's deadline is unaffected (one-sided)", got == 0.5, f"got {got}")

mut = sb / "mutant"
(mut / "lib").mkdir(parents=True)
for f in LIB.glob("aidd_cc*.py"):
    shutil.copy(f, mut / "lib" / f.name)
shutil.copy(LIB / "aidd-cc-adapter.sh", mut / "lib" / "aidd-cc-adapter.sh")
src = (LIB / "aidd_cc_text.py").read_text(encoding="utf-8")
needle = "typed = user_authored_text(typed)"
if needle not in src:
    check("code mutant: mutation anchor present in aidd_cc_text.py", False, f"missing `{needle}` — update this test with the refactor")
else:
    (mut / "lib" / "aidd_cc_text.py").write_text(src.replace(needle, "typed = typed"), encoding="utf-8")
    got = deadline_hours(mut / "lib", "dsrc-mut-code-neg", NOTIFICATION)
    check("code mutant (source check removed): the incident notification sets a deadline again", got == 0.25, f"got {got}")
    got = deadline_hours(mut / "lib", "dsrc-mut-code-pos", "この修正を30分以内に終えて")
    check("code mutant (source check removed): a user's deadline is unaffected (one-sided)", got == 0.5, f"got {got}")

print(f"h17 deadline source: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
PY
