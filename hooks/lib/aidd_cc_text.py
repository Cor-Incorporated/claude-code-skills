#!/usr/bin/env python3
"""Text analysis for the AIDD common control (H17).

Pure functions only: no I/O.  Everything here is deliberately *surface-form*
matching (C15: no semantic judgement).  Each function says which DOT-INC case
it exists for, so the replay runner can tie a red/green to a line.

Mutation knock-out points are named `mutated("<id>")` so that the replay runner
can disable exactly one control and prove the oracle goes red (片側変異).
"""

from __future__ import annotations

import os
import re
from typing import Iterable

PERSIST_WORDS = (
    r"保存済み|保存した|保存しました|保存完了|deployed|配備済み|配備した|配備しました|反映済み|反映した|反映しました|"
    r"applied|installed|インストール済み|書き込み済み|written to|\bsaved\b|persisted"
)
COMPLETION_CLAIM_RE = re.compile(
    r"(?<![A-Za-z])(verified|完了|根因確定|検証済み|実装済み|解決済み|対応済み|"
    r"done|all (tests )?pass(ed)?|全件\s*PASS|merged|マージ済み|マージした|pushed|push済み|published|"
    + PERSIST_WORDS + r")(?![A-Za-z])",
    re.IGNORECASE,
)
PERSIST_CLAIM_RE = re.compile(r"(" + PERSIST_WORDS + r")", re.IGNORECASE)
PUSH_CLAIM_RE = re.compile(
    r"(pushed|push済み|push した|merged|マージ済み|マージした)", re.IGNORECASE
)
UNMET_RE = re.compile(
    r"(未達|UNMET|期限超過|deadline (missed|exceeded)|間に合(わ|い)ません|未完了)"
)
EVIDENCE_LINE_RE = re.compile(r"^\s*Evidence:\s*(.+?)\s*$", re.MULTILINE)
READBACK_LINE_RE = re.compile(
    r"^\s*Readback:\s*(?P<path>\S+)\s+sha256=(?P<sha>[0-9a-fA-F]{64})\s*$", re.MULTILINE
)
RATIO_RE = re.compile(r"(?<![\d./])(\d{1,4})\s*/\s*(\d{1,4})(?![\d./])")
WHOLE_WORDS = ("全体", "全ケース", "全件", "all cases", "overall", "原要求")

NEGATION_RE = re.compile(
    r"(しない|しません|しないで|してはいけ|していません|していない|しかね|できません|できない|出せない|不可|不許可|禁止|ダメ|駄目|"
    r"やめて|やめろ|拒否|NG|却下|承認待ち|未承認|保留|取り消|取消|撤回|認めない|認めません|中止|停止して|考え中|検討中|考えさせ|"
    r"\bnot\b|\bdon'?t\b|\bdo not\b|\bnever\b|\bno\b|\bwon'?t\b|\bcan'?t\b|\bcannot\b|\breject|\brevoke|\bwithdraw|\bcancel|\bhold\b)",
    re.IGNORECASE,
)
NEGATED_COMPLETION_RE = re.compile(
    r"(未完了|未マージ|未配備|未保存|未反映|未push|未検証|未実装|未対応|未解決|完了ではありません|完了予定|nothing is done|"
    r"(?:完了|マージ|配備|保存|反映|push|deploy)(?:は|を)?(?:まだ)?(?:してい(?:ない|ません)|していない|できていない|ではない|していません)|"
    r"not (?:yet )?(?:done|verified|fixed|complete[d]?|merged|deployed|saved|pushed|applied|installed)|"
    r"isn'?t (?:done|verified|merged|deployed|saved)|incomplete|un(?:merged|deployed|saved|pushed))",
    re.IGNORECASE,
)
APPROVAL_RE = re.compile(
    r"(承認|許可|進めて|進めろ|進めてください|問題ない|構わない|いいです|ＯＫ|"
    r"\b(?:ok|okay|approved?|go ahead|proceed|yes|lgtm)\b)",
    re.IGNORECASE,
)
CONFIRM_Q_RE = re.compile(r"(よいですか|いいですか|よろしいですか|してもいい|進めてよ|承認|許可|may i|should i|can i|shall i|ok to|proceed\?)", re.IGNORECASE)
DESTRUCTIVE_Q_RE = re.compile(r"(削除|消して|drop|rm -rf|force|-f\b|本番|production|prod\b|決済|課金|payment|送金|秘密|secret|権限|permission|公開|publish)", re.IGNORECASE)
CHOICE_Q_RE = re.compile(r"(どちら|どれ|いずれ|\bwhich\b|\bor\b|選択|選んで|\bA/B\b|\?\s*\(?[a-c]\))", re.IGNORECASE)
DENOMINATOR_RE = re.compile(r"(?:分母|denominator)\s*[:：=]?\s*(\d{1,4})|全\s*(\d{1,4})\s*(?:ケース|件|cases?)")
TRIVIAL_CMD_RE = re.compile(r"^\s*(ls|echo|printf|cat|pwd|true|false|tail|head|wc|date|sleep|cd|which|type|env|export)\b")

DEADLINE_RE = re.compile(
    r"(?:(\d{1,3})\s*(?:h|時間)\s*以内|within\s+(\d{1,3})\s*h(?:ours?)?|"
    r"(\d{1,3})\s*(?:分|min(?:utes?)?)\s*以内)",
    re.IGNORECASE,
)
STOPWORDS = {
    "the",
    "and",
    "for",
    "with",
    "this",
    "that",
    "する",
    "ます",
    "です",
    "して",
    "ください",
    "please",
    "you",
    "can",
    "should",
    "will",
    "want",
    "need",
    "どう",
    "ですか",
    "しますか",
    "か",
    "を",
    "に",
    "は",
    "が",
    "の",
    "で",
    "も",
}


def mutated(control_id: str) -> bool:
    """True when AIDD_CC_MUTATE lists this control (one-sided mutation).

    AIDD_CC_DISABLE=1 knocks out *every* control: that is the replay "before"
    arm (control absent), so evaluator-side functions reproduce the old
    behaviour the same way the hook adapters do.
    """
    if os.environ.get("AIDD_CC_DISABLE") == "1":
        return True
    raw = os.environ.get("AIDD_CC_MUTATE", "")
    return control_id in {p.strip() for p in raw.split(",") if p.strip()}


def has_completion_claim(text: str) -> bool:
    """DOT-INC-010/017/026: a completion/verification claim is present.

    Negated completions (未完了 / 完了していません / not done) are removed first so an
    honest unmet report is never treated as a claim (Codex review P2-7).
    """
    cleaned = NEGATED_COMPLETION_RE.sub(" ", text or "")
    return bool(COMPLETION_CLAIM_RE.search(cleaned))


def has_persist_claim(text: str) -> bool:
    """DOT-INC-017/020/026: claims that something was saved/deployed (negations removed first)."""
    return bool(PERSIST_CLAIM_RE.search(NEGATED_COMPLETION_RE.sub(" ", text or "")))


def has_push_claim(text: str) -> bool:
    return bool(PUSH_CLAIM_RE.search(NEGATED_COMPLETION_RE.sub(" ", text or "")))


def has_unmet_report(text: str) -> bool:
    """DOT-INC-004/045: deadline passed must be reported as unmet, not hidden."""
    return bool(UNMET_RE.search(text or ""))


def evidence_commands(text: str) -> list[str]:
    """Commands cited in `Evidence: <cmd> | <output> | <time>` trailers."""
    cmds = []
    for line in EVIDENCE_LINE_RE.findall(text or ""):
        head = line.split("|", 1)[0].strip()
        if head:
            cmds.append(head)
    return cmds


def readback_claims(text: str) -> list[tuple[str, str]]:
    return [
        (m.group("path"), m.group("sha").lower())
        for m in READBACK_LINE_RE.finditer(text or "")
    ]


def normalize_cmd(cmd: str) -> str:
    """Whitespace/quote normalisation for ledger matching (never semantics)."""
    cmd = re.sub(r"\s+", " ", (cmd or "").strip())
    return cmd.replace('"', "").replace("'", "")


def shell_segments(cmd: str) -> list[str]:
    """Split a shell line into command segments on ; | & and newlines, ignoring
    separators inside single/double quotes (`printf '%s' 'a;pytest'` is one
    segment)."""
    return [seg for seg, _sep in shell_segments_with_separators(cmd)]


def shell_segments_with_separators(cmd: str) -> list[tuple[str, str]]:
    """Like shell_segments but returns (segment, separator_before_it); the
    separator is "" for the first segment, else one of && || ; | & \n."""
    out, cur, quote, i, sep = [], [], None, 0, ""
    text = cmd or ""
    while i < len(text):
        ch = text[i]
        two = text[i:i + 2]
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
            i += 1
        elif ch in ("'", '"'):
            quote = ch
            cur.append(ch)
            i += 1
        elif two in ("&&", "||"):
            out.append(("".join(cur), sep))
            cur, sep = [], two
            i += 2
        elif ch in (";", "|", "&", "\n"):
            out.append(("".join(cur), sep))
            cur, sep = [], ch
            i += 1
        else:
            cur.append(ch)
            i += 1
    out.append(("".join(cur), sep))
    return [(re.sub(r"\s+", " ", seg.strip()), s) for seg, s in out if seg.strip()]


def segment_runs(seg: str, cited: str) -> bool:
    """A segment ran the cited command when it is the whole segment, or the
    cited text followed only by redirections (`pytest -q 2>&1`).  `pytest -q --co`
    does NOT satisfy `pytest -q` (reviewer-d #7)."""
    if seg == cited:
        return True
    if seg.startswith(cited + " "):
        rest = seg[len(cited):].strip()
        return bool(re.match(r"^(\d?>>?|<|2>&1)", rest))
    return False


def cmd_in_ledger(cited: str, executed: Iterable[str]) -> bool:
    """A cited command counts as executed only if a ledger row ran it at a
    command position (a quote-aware segment equals it, modulo redirections).
    A command that merely appears inside an argument is not execution."""
    norm = re.sub(r"\s+", " ", (cited or "").strip())
    if len(norm) < 4:
        return False
    for row in executed:
        for seg in shell_segments(str(row)):
            if segment_runs(seg, norm):
                return True
    return False


def ratio_claims(text: str) -> list[tuple[int, int]]:
    return [(int(a), int(b)) for a, b in RATIO_RE.findall(text or "")]


def denominator_mismatch(text: str, denominator: int | None) -> list[str]:
    """DOT-INC-033: `11/12` near 全体/全ケース with a registered denominator N!=12."""
    if not denominator:
        return []
    if mutated("evidence.denominator"):
        return []
    problems = []
    for num, den in ratio_claims(text):
        if den == denominator:
            continue
        window = _window_around(text, f"{num}/{den}")
        if any(w in window for w in WHOLE_WORDS):
            problems.append(
                f"{num}/{den} presented as whole but registered denominator is {denominator}"
            )
    return problems


def _window_around(text: str, needle: str, radius: int = 40) -> str:
    idx = text.find(needle)
    if idx < 0:
        return ""
    return text[max(0, idx - radius) : idx + len(needle) + radius]


def tokens(text: str) -> set[str]:
    """Content tokens: ASCII words >=2 chars, kanji/katakana runs and their bigrams.

    Hiragana runs are grammar, not content, so they are dropped (otherwise every
    Japanese question overlaps every other one on です/ますか).
    """
    out: set[str] = set()
    for w in re.findall(r"[A-Za-z0-9_./-]{2,}", text or ""):
        wl = w.lower()
        if wl not in STOPWORDS:
            out.add(wl)
    for run in re.findall(r"[\u30a0-\u30ff\u4e00-\u9fff]{2,}", text or ""):
        out.add(run)
        for i in range(len(run) - 1):
            out.add(run[i : i + 2])
    return out


def overlap(a: str, b: str) -> float:
    """How much of the QUESTION (a) is already contained in the decision (b).

    Divides by the question's own tokens, so a question that introduces new
    content (削除 / 本番DB) scores low even when the decision is a sub-topic of
    it (reviewer-d new defect 1)."""
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta)


def is_approval_text(text: str) -> bool:
    """A user decision is registered only when approval words appear WITHOUT a
    negation / hold marker in the same text (Codex review P1-1: `許可しません` must
    never become an allow)."""
    t = text or ""
    return bool(APPROVAL_RE.search(t)) and not NEGATION_RE.search(t)


def parse_deadline_hours(text: str) -> float | None:
    """`6h以内` / `within 2h` / `30分以内` -> hours.  None if absent."""
    m = DEADLINE_RE.search(text or "")
    if not m:
        return None
    if m.group(1):
        return float(m.group(1))
    if m.group(2):
        return float(m.group(2))
    if m.group(3):
        return float(m.group(3)) / 60.0
    return None


def matching_decision(question: str, decisions: list[dict], threshold: float = 0.6) -> dict | None:
    """DOT-INC-003/008/013/025: a confirmation question already answered by the user.

    Returns the best prior decision that contains >= threshold of the question's
    tokens.  Mutation `decision.match` disables matching (re-asks every time).
    """
    if mutated("decision.match"):
        return None
    best, best_score = None, 0.0
    for d in decisions:
        score = overlap(question, d.get("text", ""))
        if score >= threshold and score > best_score:
            best, best_score = dict(d, score=round(score, 3)), score
    return best


def command_bound(decision_text: str, request: str) -> bool:
    """Strict binding for PermissionRequest: the normalised request must appear
    in the decision text as the WHOLE approved operation — bounded on the left,
    and followed by nothing ASCII except an approval word.  So `rm -rf data/archive`
    never covers `rm -rf data`, `feat/xyz` never covers `feat/x`, and approving
    `git push origin feat/x --dry-run` never covers `git push origin feat/x`
    (Codex r3 P1-1).  Topical similarity never grants permission."""
    req = re.sub(r"\s+", " ", (request or "").strip())
    dec = re.sub(r"\s+", " ", (decision_text or ""))
    if len(req) < 3:
        return False
    pat = (r"(?<![\w./:@~-])" + re.escape(req)
           + r"(?![\w./:@~-])(?!\s+(?!(?:ok|okay|yes|approved?|lgtm|go ahead|proceed)\b)[-A-Za-z0-9_./:@~])")
    return re.search(pat, dec, re.IGNORECASE) is not None


def is_confirmation_question(question: str) -> bool:
    """Re-ask suppression applies only to yes/no confirmations of something the
    user already said: never to choice questions, and never to questions that
    name a destructive / production / secret / permission operation."""
    q = question or ""
    return bool(CONFIRM_Q_RE.search(q)) and not CHOICE_Q_RE.search(q) and not DESTRUCTIVE_Q_RE.search(q)


def parse_denominator(text: str) -> int | None:
    m = DENOMINATOR_RE.search(text or "")
    if not m:
        return None
    return int(m.group(1) or m.group(2))


def is_trivial_cmd(cmd: str) -> bool:
    return bool(TRIVIAL_CMD_RE.match(cmd or ""))
