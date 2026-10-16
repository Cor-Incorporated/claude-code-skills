#!/usr/bin/env python3
"""The three controls of the AIDD common control (H17).

  C-ITER     DOT-INC-001/002/009/012/013/019/037  unproductive iteration
  C-DECISION DOT-INC-003/008                      re-asking an answered confirmation (auto-allow retired 2026-10-14)
  C-EVIDENCE DOT-INC-006/010/017/020/026/033/043  evidence-free completion

Each returns {"decision": "allow"|"block"|"warn", "rule": ..., "reason": ...}.
Adapters translate that into each harness's wire format.
"""

from __future__ import annotations

import ast
import hashlib
import re
import time
from pathlib import Path

from aidd_cc_eval import deadline_status, file_sha
from aidd_cc_text import (
    STRATEGY_NOTE_RE,
    cmd_in_ledger,
    commit_subject,
    fix_scope,
    fix_scope_from_output,
    has_commit_segment,
    segment_runs,
    shell_segments_raw,
    shell_segments_with_separators,
    is_confirmation_question,
    is_trivial_cmd,
    denominator_mismatch,
    evidence_trailers,
    incomplete_evidence_lines,
    output_field_matches,
    output_numbers_missing,
    has_completion_claim,
    has_persist_claim,
    has_push_claim,
    has_unmet_report,
    matching_decision,
    mutated,
    normalize_cmd,
    readback_claims,
)

ITER_THRESHOLD = 4  # the 4th occurrence with no progress is blocked
REPAIR_FAMILY_THRESHOLD = (
    3  # aidd-governance#88: 3 same-family fix commits without re-adjudication
)
ITER_WINDOW = 20
TEST_RE = re.compile(
    r"(pytest|jest|vitest|npm test|pnpm test|bun test|go test|cargo test|bash tests?/|python3? -m unittest|make test)"
)
BUILD_RE = re.compile(r"(npm run build|pnpm build|tsc\b|cargo build|go build|make\b)")
LINT_RE = re.compile(r"(eslint|ruff|flake8|shellcheck|prettier|black\b)")


def family(tool: str, tool_input: dict) -> str:
    """Coarse command family for streak detection (surface form only)."""
    if tool in ("Edit", "Write", "MultiEdit", "edit", "write"):
        return "edit:" + str(
            tool_input.get("file_path") or tool_input.get("path") or "?"
        )
    cmd = str(tool_input.get("command") or tool_input.get("cmd") or "")
    if TEST_RE.search(cmd):
        return "test-run"
    if BUILD_RE.search(cmd):
        return "build"
    if LINT_RE.search(cmd):
        return "lint"
    return "other"


def _norm_key(tool: str, tool_input: dict) -> str:
    if tool in ("Edit", "Write", "MultiEdit"):
        import json as _json

        body = (
            str(tool_input.get("old_string", ""))
            + "\x00"
            + str(tool_input.get("new_string", ""))
            + "\x00"
            + str(tool_input.get("content", ""))
            + "\x00"
            + _json.dumps(
                tool_input.get("edits", ""), ensure_ascii=False, sort_keys=True
            )
        )
        digest = hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()[:12]
        return f"edit:{tool_input.get('file_path', '')}:{digest}"  # distinct edits differ (P2-5)
    wd = str(tool_input.get("workdir") or tool_input.get("cwd") or "")
    return normalize_cmd(str(tool_input.get("command") or ""))[:4000] + (
        f" @{wd}" if wd else ""
    )


def repair_family_check(rows: list[dict], meta: dict, cmd: str) -> dict | None:
    """C-ITER-FAMILY (aidd-governance#88 at the session entry, found on
    2026-10-14 when this harness's own author ran 8 review→fix rounds on one
    feature): the 4th `fix(<scope>)` commit of the same scope, with no
    re-adjudication note since the first, is blocked.  A re-adjudication is a
    note whose hypothesis carries `STRATEGY: HOLD|PIVOT|RETIRE` (#88 closed
    vocabulary).  Normal development is untouched: feat/docs/test commits and
    fixes of different scopes never count."""
    scope = fix_scope(cmd)
    if not scope or mutated("iter.repair-family"):
        return None
    strat_ts = max(
        [
            n["ts"]
            for n in meta.get("notes", [])
            if STRATEGY_NOTE_RE.search(n.get("hypothesis", ""))
        ]
        or [0]
    )
    prior = [
        r
        for r in rows
        if r.get("event") == "post"
        and r.get("rc") == 0
        and (
            fix_scope(str(r.get("cmd", "")))
            or (
                has_commit_segment(
                    str(r.get("cmd", ""))
                )  # #186 R4: a read of a log is not a commit
                and fix_scope_from_output(str(r.get("out_sample", "")))
            )
        )
        == scope
        and r.get("ts", 0) > strat_ts
    ]
    if len(prior) >= REPAIR_FAMILY_THRESHOLD:
        sid = meta.get("session", "<session>")
        subject = (commit_subject(cmd) or "")[:80]
        return {
            "decision": "block",
            "rule": "iter.repair-family",
            "streak": len(prior) + 1,
            "reason": (
                f"{len(prior)} fix({scope}) commits already landed in this session with no re-adjudication "
                f"(aidd-governance#88); this commit's subject: `{subject}`. Decide the strategy before the next repair: python3 "
                f"~/.claude/hooks/lib/aidd_cc.py note --agent {meta.get('agent', 'claude-code')} --session {sid} "
                "--hypothesis 'STRATEGY: HOLD|PIVOT|RETIRE — why' --change '...'"
            ),
        }
    return None


def iteration_check(rows: list[dict], meta: dict, tool: str, tool_input: dict) -> dict:
    """C-ITER: the same command recurs with no progress delta.

    Counts occurrences of this exact key among the last ITER_WINDOW pre rows
    (interleaved edits / `true` calls do NOT reset the count: edit-test-edit-test
    with the same failing test is the dot loop).  A progress delta resets it:
    (a) the key's recorded rc changed between occurrences, or (b) a hypothesis
    note was recorded after the first occurrence.  The 4th occurrence without
    a delta is blocked.  Mutation `iter.progress-delta` ignores (a)/(b);
    `iter.threshold` disables the block.
    """
    key = _norm_key(tool, tool_input)
    fam = family(tool, tool_input)
    family_block = repair_family_check(rows, meta, str(tool_input.get("command") or ""))
    if family_block:
        return family_block
    if fam == "other" and not key.startswith("edit:"):
        return {"decision": "allow", "rule": "iter", "streak": 0}
    note_ts = max([n["ts"] for n in meta.get("notes", [])] or [0])
    pres = [r for r in rows if r.get("event") == "pre"][-ITER_WINDOW:]
    same = [r for r in pres if r.get("key") == key]
    if same and note_ts > same[0].get("ts", 0) and not mutated("iter.progress-delta"):
        same = [r for r in same if r.get("ts", 0) > note_ts]
    rcs = [
        r.get("rc")
        for r in rows
        if r.get("event") == "post"
        and r.get("key") == key
        and (mutated("iter.progress-delta") or r.get("ts", 0) > note_ts)
    ]  # same reset point as `same` (Codex r8 P2-a)
    if len(set(rcs)) > 1 and not mutated("iter.progress-delta"):
        last_change = max(i for i in range(1, len(rcs)) if rcs[i] != rcs[i - 1])
        same = (
            same[-(len(rcs) - last_change) :]
            if len(rcs) - last_change < len(same)
            else same[-1:]
        )
    streak = len(same)
    if streak >= ITER_THRESHOLD - 1 and not mutated("iter.threshold"):
        sid = meta.get("session", "<session>")
        return {
            "decision": "block",
            "rule": "iter.repeat-without-delta",
            "streak": streak + 1,
            "reason": (
                f"this would be occurrence {streak + 1} of the same {fam} command with no progress "
                "delta (rc unchanged, no new hypothesis). Record the hypothesis and the minimal "
                f"change first: python3 ~/.claude/hooks/lib/aidd_cc.py note --agent {meta.get('agent', 'claude-code')} --session {sid} "
                "--hypothesis '...' --change '...'"
            ),
        }
    return {"decision": "allow", "rule": "iter", "streak": streak}


def register_note(meta: dict, hypothesis: str, change: str) -> dict:
    digest = hashlib.sha256((hypothesis + "\n" + change).encode()).hexdigest()
    if any(n["sha"] == digest for n in meta.get("notes", [])) and not mutated(
        "iter.progress-delta"
    ):
        return {
            "decision": "block",
            "rule": "iter.note-duplicate",
            "reason": "identical hypothesis already recorded; a repeat is not a new hypothesis",
        }
    meta.setdefault("notes", []).append(
        {
            "ts": time.time(),
            "sha": digest,
            "hypothesis": hypothesis[:300],
            "change": change[:300],
        }
    )
    return {"decision": "allow", "rule": "iter.note", "sha": digest}


def question_check(meta: dict, question: str) -> dict:
    """C-DECISION: refuse to re-ask a yes/no confirmation the user already gave.

    Only confirmation-shaped questions are candidates (choice / destructive
    questions pass), and only decisions that carried an approval word count.
    A question that passes is remembered as pending so a short `OK` reply can
    bind to it (reviewer-e #8)."""
    if not is_confirmation_question(question):
        meta.setdefault("questions", []).append(
            {"ts": time.time(), "text": question[:600]}
        )
        return {
            "decision": "allow",
            "rule": "decision.not-a-confirmation",
            "remember": True,
        }
    hit = matching_decision(question, meta.get("decisions", []))
    if hit:
        return {
            "decision": "block",
            "rule": "decision.already-answered",
            "reason": (
                f"already decided by the user at {hit['at']} (overlap {hit['score']}): "
                f'"{hit["text"][:160]}" — proceed on that decision instead of re-asking'
            ),
            "decision_ref": hit["sha"],
        }
    meta.setdefault("questions", []).append({"ts": time.time(), "text": question[:600]})
    return {"decision": "allow", "rule": "decision", "remember": True}


def _executed_commands(rows: list[dict]) -> list[str]:
    return [
        str(r.get("cmd", "")) for r in rows if r.get("event") == "post" and r.get("cmd")
    ]


def _line_rc_applies(line: str) -> bool:
    """The recorded rc describes every segment only for a single command or a
    pure `&&` chain; `;`, `||`, `|`, `&` can mask a failure."""
    parts = shell_segments_with_separators(line)
    seps = {sp for _x, sp in parts if sp}
    return len(parts) == 1 or seps <= {"&&"}


def _evidence_row(rows: list[dict], cited: str) -> dict | None:
    """The newest post row that ran the cited command: the whole line equals it, or a
    quote-aware segment equals it modulo redirections (same rule as cmd_in_ledger)."""
    norm = re.sub(r"\s+", " ", cited.strip())
    for r in reversed(rows):
        if r.get("event") != "post":
            continue
        line = str(r.get("cmd", ""))
        whole = re.sub(r"\s+", " ", line.strip()) == norm
        seg_hit = any(
            segment_runs(seg, norm) for seg, _sp in shell_segments_with_separators(line)
        )
        if whole or seg_hit:
            return r
    return None


def _rc_for(rows: list[dict], cited: str):
    """Exit status attributable to the cited command.  Whole-line citations and
    segment matches both get the line's rc only when nothing in the line can
    mask a failure (`pytest -q; true` cited verbatim is still UNKNOWN,
    Codex r5 P2-a)."""
    r = _evidence_row(rows, cited)
    if r is None:
        return None, 0
    norm = re.sub(r"\s+", " ", cited.strip())
    line = str(r.get("cmd", ""))
    whole = re.sub(r"\s+", " ", line.strip()) == norm
    parts = shell_segments_with_separators(line)
    if (
        r.get("rc_src") == "marker"
        and len(parts) == 2
        and parts[1][1] in (";", "\n")
        and re.fullmatch(r"echo exit=\$\?", parts[1][0])
        and (whole or segment_runs(parts[0][0], norm))
    ):
        return r.get("rc"), r.get(
            "out_bytes", 0
        )  # `X; echo exit=$?`: the marker IS X's status (Codex r6 P2-a)
    return (r.get("rc") if _line_rc_applies(line) else None), r.get("out_bytes", 0)


def _iso(ts) -> str:
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(ts)))
    except (TypeError, ValueError):
        return "?"


def _output_problems(cited: str, claimed: str, row: dict) -> list[str]:
    """aidd-governance#186 P1-1: the trailer's output field must describe what the cited
    command printed (independent-review-probe: `git status` printed "ok", the report
    claimed "47/47 pass").  Rows written before `out_sample` existed are not judged."""
    recorded = row.get("out_sample")
    if recorded is None:
        return []
    head = re.sub(r"\s+", " ", str(recorded).strip())[:60]
    if output_field_matches(claimed, str(recorded)) is False:
        return [
            f"evidence output field does not describe the recorded output of `{cited[:60]}`: "
            f"cited `{claimed[:60]}` but the command printed `{head}` (DOT-INC-017)"
        ]
    missing = output_numbers_missing(claimed, str(recorded))  # #186 R1
    if missing:
        return [
            f"evidence output field cites numbers {missing} that `{cited[:60]}` never printed: "
            f"cited `{claimed[:60]}` but the command printed `{head}` (DOT-INC-017)"
        ]
    return []


def _edit_key_path(key: str) -> str:
    return key[5:].rsplit(":", 1)[0] if key.count(":") >= 2 else key[5:]


def _last_write_row(rows: list[dict]) -> tuple[dict, str, str] | None:
    """Newest successful write in the session: an Edit/Write/MultiEdit post row, or a Bash post
    row that wrote a path (cp/mv destination, tee/touch/sed -i/patch arguments, `>` targets —
    the same rule as _touched_paths).  Returns (row, path, how) with how = "edited" for the
    edit tools and "written" for a shell write (aidd-governance#186 R2: `pytest -q` → `sed -i`
    → citing the old pytest run was allowed because only Edit rows were considered)."""
    last: tuple[dict, str, str] | None = None
    for r in rows:
        if r.get("event") != "post":
            continue
        key = str(r.get("key", ""))
        if key.startswith("edit:"):
            if r.get("rc") not in (0, None):
                continue
            path, how = _edit_key_path(key), "edited"
        else:
            paths = _row_written_paths(r)
            if not paths:
                continue
            path, how = paths[-1], "written"
        if last is None or r.get("ts", 0) >= last[0].get("ts", 0):
            last = (r, path, how)
    return last


def _stale_problems(cited: str, row: dict, last: tuple[dict, str, str] | None) -> list[str]:
    """aidd-governance#186 P1-2 / R2: evidence recorded before the newest successful write (`last`, computed
    once per Stop — review #8 F-2) no longer describes the tree.  Any written file counts — the conservative side."""
    if last is None or row.get("ts", 0) >= last[0].get("ts", 0):
        return []
    edit, path, how = last
    by = (
        f" by `{re.sub(r'\\s+', ' ', str(edit.get('cmd', '')).strip())[:80]}`"
        if how == "written"
        else ""
    )
    verb = "edit" if how == "edited" else "write"
    return [
        f"evidence `{cited[:60]}` ran at {_iso(row.get('ts'))} but {path} was {how} later at "
        f"{_iso(edit.get('ts'))}{by}; re-run it after the {verb} (DOT-INC-017)"
    ]


WRITE_CMD_RE = re.compile(
    r"^(cp|mv|tee|install|rsync|ln|touch|dd|patch|git apply|git checkout|sed -i|curl .*-o|wget .*-O|python3? .*\.py|node .*\.m?js|bash .*\.sh)\b"
)


MAX_TRAILERS = 20  # ruling on review #8 F-2: trailers beyond 20 are not evaluated and are a block-side problem
WRITE_LAST_RE = re.compile(r"^(cp|mv|rsync|install|ln)\b")
# Review 2026-10-16 P2-b + Codex rounds: a real sed / perl `-i` cluster, the formatter verbs and `git restore` (worktree
# form) write every path argument; check / diff / emit-stdout modes, index-only restore and option VALUES are reads;
# `python -c` code is parsed with `ast` (never executed): only open(w|a|x|+) / Path.write_* CALLS that run write.
_NO_CHECK = r"(?!(?: \S+)* (?:--(?:check|check-only|diff|help|version|stdout|show-config|show-files)|-h|-V|-c|-d|--emit[= ](?:stdout|checkstyle|json))\b)"  # read-only modes (Codex 1397e64 P1, e00d1df P2)
WRITE_ALL_RE = re.compile(
    r"^(tee|touch|patch|git apply|git checkout|sed(?=(?: +\S+)* +(?:-[nrEsuz]*i\S*|--in-place\b))|perl(?=(?: +\S+)* +-[plnaw0-9CSD]*i\S*)|"
    r"git restore(?!(?=(?: \S+)* (?:--staged|-[a-zA-Z]*S[a-zA-Z]*)\b)(?!(?: \S+)* (?:--worktree|-[a-zA-Z]*W[a-zA-Z]*)\b))|"
    r"(?:ruff format|black|isort|rustfmt|gofmt -w|dos2unix|unix2dos)" + _NO_CHECK + r"|"
    r"ruff check(?=(?: \S+)* --fix\b)" + _NO_CHECK + r"|prettier(?=(?: \S+)* (?:--write|-w)\b)" + _NO_CHECK + r"|"
    r"eslint(?=(?: \S+)* --fix\b)(?!(?: \S+)* --fix-dry-run\b))\b"
)
EXTLESS_FILES = frozenset("Makefile Dockerfile Containerfile LICENSE README CHANGELOG Procfile Gemfile Rakefile Vagrantfile Jenkinsfile".split())  # review #8 F-6
FORMATTER_RE = re.compile(r"^(?:ruff|black|isort|prettier|eslint|rustfmt|gofmt|git restore)\b")  # verbs whose option VALUES are inputs (git restore --pathspec-from-file: Codex 4d4561b P2)
TARGET_DIR_RE = re.compile(r"(?:^|\s)(?:--target-directory[= ]|-t\s+)([\w./~-]+)")
OPTION_VALUE_RE = re.compile(
    r"(?:^|\s)(?:--config|-c|--settings-path|--rcfile|--ignore-path|--ignore-pattern|--stdin-filename|--parser|--line-length|-l|"
    r"--target-version|-t|--extend-exclude|--exclude|--include|--source|--pathspec-from-file)\s+(\S+)"
)
PY_CMD_RE = re.compile(r"^python[0-9.]*(?: -[A-Za-z]+)* -c\s+")


def _py_code_arg(seg: str) -> str:
    """The code argument of `python -c <code>` as the shell would pass it (quotes and escapes resolved)."""
    m = PY_CMD_RE.match(seg)
    rest = seg[m.end() :] if m else ""
    if rest[:1] == "'":
        end = rest.find("'", 1)
        return rest[1:] if end < 0 else rest[1:end]
    if rest[:1] == '"':
        out, i = [], 1
        while i < len(rest):
            ch = rest[i]
            if ch == "\\" and i + 1 < len(rest):
                out.append(rest[i + 1])
                i += 2
                continue
            if ch == '"':
                break
            out.append(ch)
            i += 1
        return "".join(out)
    return rest.split(None, 1)[0] if rest else ""


def _is_path_ctor(func: ast.AST) -> bool:
    """`Path(...)` or `pathlib.Path(...)`."""
    return (isinstance(func, ast.Name) and func.id == "Path") or (
        isinstance(func, ast.Attribute) and func.attr == "Path"
    )


def _str_const(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


def _top_level_nodes(tree: ast.AST, called: frozenset[str] = frozenset()):
    """ast.walk; a def / lambda body is walked only when the def is called at top level (review #5 P2)."""
    stack = [tree]
    while stack:
        node = stack.pop()
        yield node
        if isinstance(node, (ast.If, ast.While)) and isinstance(node.test, ast.Constant) and not node.test.value:
            stack.extend(node.orelse)  # `if False:` / `while 0:` never runs its body (Codex 4d4561b P2)
            continue
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            if getattr(node, "name", None) in called:  # generator / async bodies count too (review #8 F-3, block side)
                stack.extend(ast.iter_child_nodes(node))
            else:  # kw_defaults holds None for a required kw-only arg (Codex e00d1df P1)
                stack.extend(n for n in node.args.defaults + node.args.kw_defaults + list(getattr(node, "decorator_list", [])) if n is not None)
            continue
        stack.extend(ast.iter_child_nodes(node))  # a class body runs at definition: keep walking it


def _py_written_paths(code: str) -> list[str]:
    """Literal paths that `code` opens for writing or writes through pathlib — AST calls only."""
    try:
        tree = ast.parse(code)
    except Exception:  # SyntaxError / ValueError / RecursionError / MemoryError: not a write we can read
        return []
    called = frozenset(n.func.id for n in _top_level_nodes(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name))
    out: list[str] = []
    for node in _top_level_nodes(tree, called):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        if isinstance(f, ast.Name) and f.id == "open" and node.args:
            path = _str_const(node.args[0])
            mode = _str_const(node.args[1]) if len(node.args) > 1 else None
            for kw in node.keywords:
                if kw.arg == "mode":
                    mode = _str_const(kw.value)
            if path and mode and (mode[:1] in "wax" or "+" in mode):
                out.append(path)
        elif (
            isinstance(f, ast.Attribute)
            and f.attr in ("write_text", "write_bytes")
            and isinstance(f.value, ast.Call)
            and _is_path_ctor(f.value.func)
            and f.value.args
            and _str_const(f.value.args[0])
        ):
            out.append(_str_const(f.value.args[0]))
    return out


def _row_written_paths(r: dict) -> list[str]:
    """Absolute paths one successful post row WROTE, in command order: Edit/Write keys, the
    destination of cp/mv/rsync/install/ln (last argument only — the source is not written,
    Codex r3 P2-3), the arguments of tee/touch/patch/sed -i, and `>` redirection targets.
    Merely mentioning a path does not count.  Empty when the row's success is unknown
    (`cp … || true`, Codex r5 P2-b) or it is not a write."""
    if (
        r.get("event") != "post"
        or r.get("rc") not in (0, None)
        or (r.get("rc") is None and not str(r.get("key", "")).startswith("edit:"))
    ):
        return []  # only writes that actually succeeded (Codex r4 P2-e)
    cwd = str(r.get("cwd") or "")
    key = str(r.get("key", ""))
    cands: list[str] = []
    if key.startswith("edit:"):
        cands.append(_edit_key_path(key))
    parts = shell_segments_with_separators(str(r.get("cmd", "")))
    raw: list[str] | None = None  # the un-normalised segments, split once per row (review #7 P0-T2: per-fragment was quadratic)
    for i, (seg, _sep) in enumerate(parts):
        # A write whose own result is masked (`cp a b || true`) has unknown success (Codex r5 P2-b); a write
        # followed by `;` / `|` / `&&` with the line's rc 0 is counted (review 2026-10-16: `printf x | tee a.py`).
        if i + 1 < len(parts) and parts[i + 1][1] == "||":
            continue
        bare = re.sub(
            r" {2,}", " ", _unquoted(seg)
        )  # `git commit -m "a > b"` / `awk '$1 > 5'`: no redirection inside quotes; blanks collapsed (Codex 2741d2c P2)
        # `--in-place=.bak` / `--source=HEAD`: the value of a long option is not a path argument (review #2 P3)
        args = [t for t in re.findall(r"[\w./~-]+", re.sub(r"--[\w-]+=\S*", " ", bare))[1:] if not t.startswith("-")]
        if WRITE_LAST_RE.match(bare) and args:
            tdir = TARGET_DIR_RE.search(bare)
            if tdir:  # `cp a.py --target-directory=out` / `cp a.py b.py -t out`: out/<basename> is written (Codex e00d1df P2)
                cands += [tdir.group(1).rstrip("/") + "/" + a.rsplit("/", 1)[-1] for a in args if a != tdir.group(1)]
            else:
                cands.append(args[-1])  # the destination, whatever it is called (Codex r7 P2-c)
        elif bare.startswith("git checkout"):
            if (
                " -- " in bare
            ):  # only the path form writes files; `git checkout -b feat/x` switches branches
                cands += [
                    t for t in bare.split(" -- ", 1)[1].split() if not t.startswith("-")
                ]
        elif WRITE_ALL_RE.match(bare):
            # `--config pyproject.toml`: an input (Codex 2741d2c P2), counted once each — formatters only: `patch -t` is a flag (Codex 50f31e5 P2)
            vals = list(OPTION_VALUE_RE.findall(bare)) if FORMATTER_RE.match(bare) else []
            for t in args:
                if t in vals:
                    vals.remove(t)  # review #5 P2: `black --config pyproject.toml pyproject.toml` still formats the file
                elif "/" in t or "." in t or t in EXTLESS_FILES:
                    cands.append(t)
        elif PY_CMD_RE.match(bare):
            raw = shell_segments_raw(str(r.get("cmd", ""))) if raw is None else raw  # newlines inside the quotes survive (review #5 P2)
            cands += _py_written_paths(_py_code_arg(raw[i] if i < len(raw) else seg))
        cands += re.findall(r"(?<![<>&\d])\d?>>?\s*([\w./~-]+)", bare)
    out: list[str] = []
    for c in cands:
        if c.startswith("/dev/") or "\x00" in c:
            continue  # /dev/null is not an artifact (reviewer-g); a NUL path is not a file (Codex 4d4561b P1)
        p = _expand(c) or Path(c)  # `~tmp/../src/a.py`: the literal cwd-relative path still goes stale (review #7 P0/P1-W)
        if not p.is_absolute():
            p = Path(cwd) / p if cwd else p
        try:
            resolved = str(p.resolve())
        except (OSError, ValueError, RuntimeError):  # NUL path (Codex 4d4561b P1) / symlink loop (review #8 F-4): never a fail-open
            resolved = str(p)
        if resolved not in out:
            out.append(resolved)
    return out


def _expand(path: str) -> Path | None:
    """Path.expanduser() that returns None instead of raising on `~unknownuser` (review #6 P1-R)."""
    try:
        return Path(path).expanduser()
    except (RuntimeError, OSError, KeyError):
        return None


def _unquoted(seg: str) -> str:
    """The segment with quoted CONTENT blanked, so `>` inside an argument is not a redirection (review 2026-10-16 P2)."""
    out, quote = [], None
    for ch in seg:
        if quote:
            if ch == quote:
                quote = None
                out.append(ch)
            else:
                out.append(" ")
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        else:
            out.append(ch)
    return "".join(out)


def _touched_paths(rows: list[dict]) -> set[str]:
    """Absolute paths this session WROTE (union of _row_written_paths over the ledger)."""
    out: set[str] = set()
    for r in rows:
        out.update(_row_written_paths(r))
    return out


def _push_executed(rows: list[dict]) -> bool:
    """A push/merge counts only from a successful post row whose line is a
    single segment or an `&&` chain (`false && git push …; true` is not a push)."""
    for r in rows:
        if r.get("event") != "post" or r.get("rc") != 0:
            continue
        parts = shell_segments_with_separators(str(r.get("cmd", "")))
        seps = {s for _x, s in parts if s}
        if len(parts) > 1 and not seps <= {"&&"}:
            continue
        for seg, _sep in parts:
            if re.match(r"(git push|gh pr merge|git merge)\b", seg) and not re.search(
                r"(--dry-run|\s-n\b)", seg
            ):
                return True
    return False


def stop_check(meta: dict, rows: list[dict], text: str, cwd: str) -> dict:
    """C-EVIDENCE: a completion claim must be bound to executed, readable evidence."""
    problems: list[str] = []
    ds = deadline_status(meta.get("deadline"))
    if (
        ds.get("passed")
        and not has_unmet_report(text)
        and not mutated("deadline.unmet-report")
    ):
        problems.append(
            "deadline passed: report 未達 with the original deadline and real elapsed (DOT-INC-004/045)"
        )
    if not (has_completion_claim(text) or has_persist_claim(text)):
        return _verdict(problems)
    trailers = evidence_trailers(text)
    cmds = [c for c, _out, _when in trailers]
    for bad in incomplete_evidence_lines(text):
        if not mutated("evidence.trailer"):
            problems.append(
                f"incomplete Evidence trailer (need <cmd> | <output> | <time>): {bad}"
            )
    if not cmds and not mutated("evidence.trailer"):
        problems.append(
            "completion claim without `Evidence: <cmd> | <output> | <time>` trailer (DOT-INC-010)"
        )
    executed = _executed_commands(rows)
    last_write = _last_write_row(rows)  # once per Stop, not once per trailer (review #8 F-2)
    if len(trailers) > MAX_TRAILERS:
        problems.append(f"too many Evidence trailers ({len(trailers)}); cite the commands that produced the result")
        trailers = trailers[:MAX_TRAILERS]
    substantive = False
    for c, claimed_out, _when in trailers:
        if not cmd_in_ledger(c, executed) and not mutated("evidence.executed"):
            problems.append(
                f"cited evidence command was not executed in this session: {c[:80]} (DOT-INC-017)"
            )
            continue
        row = _evidence_row(rows, c)
        if row is not None and not mutated("evidence.trailer"):
            problems.extend(_output_problems(c, claimed_out, row))  # #186 P1-1
        if row is not None and not mutated("evidence.executed"):
            problems.extend(_stale_problems(c, row, last_write))  # #186 P1-2
        rc, out_bytes = _rc_for(rows, c)
        if rc is None and mutated("evidence.executed"):
            rc = 0  # the old behaviour: a typed command is trusted as if it ran and passed
        if rc in (None, 124, 126, 127) and not mutated("evidence.rc-unknown"):
            how = (
                ""
                if rc is not None
                else " — this harness reported no exit status; run it as `<cmd>; echo exit=$?` so the status is in the output"
            )
            problems.append(
                f"evidence command exit status {rc if rc is not None else 'unavailable'} is UNKNOWN, not a result: {c[:80]}{how} (DOT-INC-043)"
            )
        elif rc != 0 and not mutated("evidence.rc-unknown"):
            problems.append(
                f"evidence command failed (rc={rc}) yet completion is claimed: {c[:80]} (DOT-INC-043)"
            )
        if not is_trivial_cmd(c):
            substantive = True
    if cmds and not substantive and not mutated("evidence.trailer"):
        problems.append(
            "every cited evidence command is trivial (ls/echo/cat/tail…); cite the command that produced the result"
        )
    if has_persist_claim(text) and not mutated("evidence.readback"):
        problems.extend(_readback_problems(text, cwd, _touched_paths(rows)))
    if has_push_claim(text) and not mutated("evidence.readback"):
        if not _push_executed(rows):
            problems.append(
                "push/merge claimed but no successful push/merge command in the session ledger (DOT-INC-026)"
            )
    problems.extend(denominator_mismatch(text, meta.get("denominator")))
    problems.extend(source_set_problems(rows))
    return _verdict(problems)


def control_sha() -> str:
    """sha256 over the control source set (DOT-INC-023: fixed for the whole run)."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256()
    for name in (
        "aidd_cc.py",
        "aidd_cc_controls.py",
        "aidd_cc_text.py",
        "aidd_cc_eval.py",
        "aidd_cc_session.py",
    ):
        try:
            h.update((here / name).read_bytes())
        except OSError:
            h.update(b"missing:" + name.encode())
    return h.hexdigest()


CONTROL_SET_EXTRA = ("aidd-cc-adapter.sh",)


def control_set_sha() -> str:
    """aidd-governance#186 P2-4: control_sha() is pinned to the five python files (its set and order are
    an identifier other tooling depends on), so the shared adapter — the file that turns a verdict into
    the Claude Code / Codex wire format — is covered by this second digest: control_sha() input plus
    CONTROL_SET_EXTRA, all read from the same directory.  Recorded as `cc_set_sha` on tool rows and
    checked by source_set_problems like cc_sha."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256(control_sha().encode())
    for name in CONTROL_SET_EXTRA:
        try:
            h.update((here / name).read_bytes())
        except OSError:
            h.update(b"missing:" + name.encode())
    return h.hexdigest()


def source_set_problems(rows: list[dict]) -> list[str]:
    """DOT-INC-023: every tool row of the run must carry the same control sha as now (python set), and
    the same control-set sha (python set + adapter, #186 P2-4) where the row recorded one."""
    if mutated("source-set.pin"):
        return []
    out = []
    now = control_sha()
    seen = {r.get("cc_sha") for r in rows if r.get("cc_sha")}
    if seen and seen != {now}:
        out.append(
            f"control source set changed during the run ({len(seen)} shas seen); acceptance refused (DOT-INC-023)"
        )
    now_set = control_set_sha()
    seen_set = {r.get("cc_set_sha") for r in rows if r.get("cc_set_sha")}
    if seen_set and seen_set != {now_set} and not out:
        out.append(
            f"control set (python + adapter) changed during the run ({len(seen_set)} set shas seen); acceptance refused (DOT-INC-023)"
        )
    return out


def _readback_problems(text: str, cwd: str, touched: set[str]) -> list[str]:
    claims = readback_claims(text)
    if not claims:
        return [
            "save/deploy claimed without `Readback: <path> sha256=<hex>` (DOT-INC-017/026)"
        ]
    out = []
    for path, sha in claims:
        p = _expand(path)
        if p is None:  # review #6 P1-R: `~nosuchuser/app.toml` raised RuntimeError and every later claim passed UNVERIFIED
            out.append(f"readback path {path} unresolvable (unknown ~user): not a saved artifact this session can verify")
            continue
        if not p.is_absolute():
            p = Path(cwd) / p
        try:
            resolved = str(p.resolve())
        except RuntimeError:  # symlink loop (ruling on review #8 F-4): block side, like an unknown ~user
            out.append(f"readback path {path} unresolvable (symlink loop): not a saved artifact this session can verify")
            continue
        except (OSError, ValueError):
            resolved = str(p)
        actual = file_sha(p)
        if actual != sha:
            out.append(
                f"readback mismatch for {path}: claimed {sha[:12]} actual {str(actual)[:12]}"
            )
        elif resolved not in touched:
            out.append(
                f"readback path {path} was never written or touched by a command in this session (not the saved artifact)"
            )
    return out


def _verdict(problems: list[str]) -> dict:
    if problems:
        return {
            "decision": "block",
            "rule": "evidence",
            "problems": problems,
            "reason": "H17 evidence gate: " + " / ".join(problems),
        }
    return {"decision": "allow", "rule": "evidence"}
