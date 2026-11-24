#!/usr/bin/env bash
# H17 deadline bounds — negative + positive tests.
# NEGATIVE-TEST-FOR: hooks/lib/aidd_cc_text.py (DEADLINE_RE / parse_deadline_hours)
#
# 起点: #488 の独立査読 (2026-11-12) が develop 2b879e3 の未修正コードで実測した。
# DEADLINE_RE は数字の左境界を持たず 0 も受けるので、`0分以内` `1000分以内` `1000時間以内` は
# 末尾の "0" / "000" に一致して 0.0 時間を返す。0 時間の期限は「いま」で、cmd_prompt が write-once で
# 保存し (aidd_cc.py の deadline_set)、以後の Stop が毎回 DOT-INC-004/045 で止められる。
# 2026-11-12 の通知事故と同じ永久ブロックを、別の原因で起こす。
# 同じ原因で、小数 `1.5時間以内` / `0.5h以内` は末尾の "5" に一致して 5.0 時間 (意図の 3.3〜10 倍) になり、
# 桁区切り `1,030分以内` は "030" に一致して 0.5 時間になる。
#
# 方針 (2026-11-12 の実測で決めた。根拠は PR 本文):
#   - 数字の左に数字・小数点・桁区切りが続くものは、数字の一部であって期限ではない → 一致させない。
#   - 一致しても 0 以下は期限ではない → 読み飛ばして次の一致を探す。
#   - 小数は受けない (失敗側を閉じる: 取りこぼしは打ち直せるが、誤った期限は write-once で残る)。
#   - 上限は設けない。3 桁の上限 (999 時間) がそのまま上限で、4 桁以上は一致しなくなる。
# 片側変異は 2 本のガードそれぞれに 1 つ (コード変異体) と、両方を外す 1 つ (AIDD_CC_MUTATE)。
# 各変異は自分のクラスの入力だけを red にし、利用者の正しい期限は付いたまま (陽性は green のまま) になること。
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
import time
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
# Each class names the guard that must reject it.  `old` is what the unmodified regex returned (measured on
# develop 2b879e3); it is the value the env mutation must reproduce.
ZERO = [  # a literal non-positive number: only the non-positive guard stops these
    ("0分以内に終えて", 0.0),
    ("00分以内に終えて", 0.0),
    ("0時間以内", 0.0),
    ("0h以内", 0.0),
    ("within 0h", 0.0),
    ("within 0 hours", 0.0),
    ("0 min以内", 0.0),
    ("0 minutes以内", 0.0),
]
TAIL_POSITIVE = [  # the digit run is longer than the unit expects and its tail is > 0: only the left boundary stops these
    ("1500分以内に終えて", 500 / 60),
    ("1,030分以内に終えて", 0.5),
    ("1，030分以内に終えて", 0.5),
    ("1.5時間以内", 5.0),
    ("0.5時間以内", 5.0),
    ("2.5h以内", 5.0),
    ("1．5時間以内", 5.0),
    ("ver2.6時間以内", 6.0),
    ("1.5分以内", 5 / 60),
    ("１５００分以内", 500 / 60),
]
TAIL_ZERO = [  # tail 0: both guards reject these, so each single-guard mutant leaves them red-free
    ("1000分以内に終えて", 0.0),
    ("1000時間以内", 0.0),
    ("1000h以内", 0.0),
    ("10000分以内", 0.0),
    ("100000分以内", 0.0),
    ("１０００分以内", 0.0),
    ("1,000時間以内", 0.0),
]
ALREADY_NONE = [  # None before and after: guards against a regression, not red on develop
    "within 1000h",
    "within 1.5h",
]
# (label, prompt, expected hours)
POSITIVE = [
    ("30分以内", "この修正を30分以内に終えて", 0.5),
    ("2時間以内", "2時間以内にお願いします", 2.0),
    ("6h以内", "6h以内で", 6.0),
    ("within 2h", "please finish within 2h", 2.0),
    ("45 min以内", "45 min以内で", 0.75),
    ("45 minutes以内", "45 minutes以内で", 0.75),
    ("within 2 hours", "within 2 hours", 2.0),
    ("a space between the number and the unit", "30 分以内に終えて", 0.5),
    ("full-width digit", "２時間以内にお願いします", 2.0),
    ("999時間以内: the 3-digit cap is the ceiling and it still works", "999時間以内", 999.0),
    ("1分以内: the smallest positive deadline is not a floor", "1分以内に", 1 / 60),
    ("a comma after a letter is punctuation, not a thousands separator", "OK,30分以内で", 0.5),
    ("a Japanese comma before the number", "お願い、30分以内で", 0.5),
    ("a numbered list item with a space: '1. 30分以内'", "1. 30分以内に終えて", 0.5),
    ("a number after a closing parenthesis", "(急ぎ)30分以内に", 0.5),
    ("a literal 0 is skipped and the next valid deadline wins", "0分以内にして。30分以内に終えて", 0.5),
    ("a 4-digit number is skipped and the next valid deadline wins", "1000分以内は長い。2時間以内で", 2.0),
    ("a decimal is skipped and the next valid deadline wins", "1.5時間以内は曖昧なので、90分以内で", 1.5),
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


def show(lib: Path, sid: str) -> dict:
    return run_cc(lib, ["deadline", "show", "--session", sid], None)


def stop_decision(lib: Path, sid: str, env_extra: dict | None = None) -> dict:
    """What the Stop hook says to an honest, ordinary partial answer (no 未達 line)."""
    return run_cc(lib, ["stop", "--session", sid], {"last_assistant_message": "調べた結果を報告します。\nStatus: partial"}, env_extra)


def close(a, b) -> bool:
    return a is not None and abs(a - b) < 1e-9


LIB = root / "hooks" / "lib"
n = 0


def sid(kind: str) -> str:
    global n
    n += 1
    return f"dbnd-{kind}-{n}"


# 1. the parser itself: nothing that is not a stand-alone positive number followed by its unit
for label, _old in ZERO + TAIL_POSITIVE + TAIL_ZERO:
    got = T.parse_deadline_hours(label)
    check(f"parser: {label!r} yields no deadline", got is None, f"got {got!r} hours")
for label in ALREADY_NONE:
    got = T.parse_deadline_hours(label)
    check(f"parser: {label!r} yields no deadline (regression guard)", got is None, f"got {got!r} hours")
for label, text, hours in POSITIVE:
    got = T.parse_deadline_hours(text)
    check(f"parser: {label} -> {hours:g}h", close(got, hours), f"expected {hours}, got {got!r}")

# 2. through the real prompt command: no deadline is registered for any rejected form
for i, (text, _old) in enumerate(ZERO + TAIL_POSITIVE + TAIL_ZERO):
    got = deadline_hours(LIB, sid("neg"), text)
    check(f"prompt command: {text!r} registers no deadline", got is None, f"registered deadline+{got}h")

# 3. every accepted form is still registered with the same hours as before
for label, text, hours in POSITIVE:
    got = deadline_hours(LIB, sid("pos"), text)
    check(f"prompt command: {label} -> {hours:g}h", close(got, hours), f"expected {hours}, got {got}")

# 4. the consequence the bug had: a 0-hour deadline is 'now', and every later Stop is blocked
HOOK = root / "hooks" / "aidd-cc-claude.sh"


def via_hook(session: str, text: str, env_extra: dict | None = None) -> None:
    subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": session, "prompt": text}, ensure_ascii=False),
        capture_output=True, text=True, env={**BASE_ENV, **(env_extra or {})}, timeout=60,
    )


for text in ("0分以内に終えて", "1000分以内に終えて", "1.5時間以内"):
    s = sid("e2e")
    via_hook(s, text)
    shown = show(LIB, s)
    check(f"hook entry: {text!r} leaves the session without a deadline", not shown.get("set"), f"deadline show={shown}")
    dec = stop_decision(LIB, s)
    check(f"stop: after {text!r} an ordinary partial answer is allowed", dec.get("decision") == "allow",
          f"decision={dec.get('decision')!r} problems={dec.get('problems')}")
s = sid("e2e")
via_hook(s, "この修正を30分以内に終えて")
shown = show(LIB, s)
check("hook entry: a user's 30分以内 still sets a 30 minute deadline",
      bool(shown.get("set")) and 1700 < float(shown.get("remaining_sec") or 0) <= 1800, f"deadline show={shown}")
check("stop: with a live 30 minute deadline an ordinary partial answer is allowed",
      stop_decision(LIB, s).get("decision") == "allow", "blocked before the deadline passed")

# 4b. time bound: the digit scan stays linear (aidd-cc-claude.sh is registered with a 10 s timeout)
for label, big in (
    ("200k digits then the unit", "9" * 200000 + "分以内"),
    ("100k comma-grouped digits then the unit", "1," * 100000 + "分以内"),
    ("100k decimals then the unit", "1." * 100000 + "5時間以内"),
):
    t0 = time.perf_counter()
    T.parse_deadline_hours(big)
    took = time.perf_counter() - t0
    check(f"time bound: {label} ({len(big):,} chars) stays under 2 s", took < 2.0, f"took {took:.2f}s")

# 5. one-sided mutations.  Each guard is load-bearing for its own class and for nothing else.
ENV_MUT = {"AIDD_CC_MUTATE": "deadline.number-bounds"}
for text, old in ZERO + TAIL_POSITIVE + TAIL_ZERO:
    got = deadline_hours(LIB, sid("mut"), text, ENV_MUT)
    check(f"mutation deadline.number-bounds: {text!r} gets the old value {old:g}h again (both guards are load-bearing)",
          close(got, old), f"expected {old}, got {got}")
for label, text, hours in POSITIVE[:5]:
    got = deadline_hours(LIB, sid("mut"), text, ENV_MUT)
    check(f"mutation deadline.number-bounds: {label} is unaffected (one-sided)", close(got, hours), f"got {got}")
s = sid("mut")
via_hook(s, "0分以内に終えて", ENV_MUT)
dec = stop_decision(LIB, s, ENV_MUT)
check("mutation deadline.number-bounds: the Stop after '0分以内に終えて' is blocked again (the permanent-block failure)",
      dec.get("decision") == "block" and "deadline passed" in json.dumps(dec, ensure_ascii=False), f"decision={dec}")

# code mutants: each removes ONE guard from a copy of the library
SRC = (LIB / "aidd_cc_text.py").read_text(encoding="utf-8")
LEFT_ANCHOR = '_NUM_LEFT = r"(?<![\\d.．])(?<!\\d[,，])"'
POS_ANCHOR = "if hours > 0 or not bounded:"


def mutant(name: str, needle: str, repl: str) -> Path | None:
    if needle not in SRC:
        check(f"code mutant ({name}): mutation anchor present in aidd_cc_text.py", False,
              f"missing `{needle}` — update this test with the refactor")
        return None
    d = sb / f"mutant-{name}"
    (d / "lib").mkdir(parents=True)
    for f in LIB.glob("aidd_cc*.py"):
        shutil.copy(f, d / "lib" / f.name)
    shutil.copy(LIB / "aidd-cc-adapter.sh", d / "lib" / "aidd-cc-adapter.sh")
    (d / "lib" / "aidd_cc_text.py").write_text(SRC.replace(needle, repl), encoding="utf-8")
    return d / "lib"


no_left = mutant("no-left-boundary", LEFT_ANCHOR, '_NUM_LEFT = r""')
if no_left:
    for text, old in TAIL_POSITIVE:
        got = deadline_hours(no_left, sid("mutL"), text)
        check(f"code mutant (left boundary removed): {text!r} gets the old value {old:g}h again", close(got, old), f"got {got}")
    for text, _old in ZERO:
        got = deadline_hours(no_left, sid("mutL"), text)
        check(f"code mutant (left boundary removed): {text!r} is still rejected by the non-positive guard (one-sided)",
              got is None, f"got {got}")
    for label, text, hours in POSITIVE[:5]:
        got = deadline_hours(no_left, sid("mutL"), text)
        check(f"code mutant (left boundary removed): {label} is unaffected (one-sided)", close(got, hours), f"got {got}")

no_pos = mutant("no-positive-guard", POS_ANCHOR, "if True:")
if no_pos:
    for text, old in ZERO:
        got = deadline_hours(no_pos, sid("mutP"), text)
        check(f"code mutant (non-positive guard removed): {text!r} gets {old:g}h again", close(got, old), f"got {got}")
    for text, _old in TAIL_POSITIVE:
        got = deadline_hours(no_pos, sid("mutP"), text)
        check(f"code mutant (non-positive guard removed): {text!r} is still rejected by the left boundary (one-sided)",
              got is None, f"got {got}")
    for label, text, hours in POSITIVE[:5]:
        got = deadline_hours(no_pos, sid("mutP"), text)
        check(f"code mutant (non-positive guard removed): {label} is unaffected (one-sided)", close(got, hours), f"got {got}")

print(f"h17 deadline bounds: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
PY
