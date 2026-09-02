#!/usr/bin/env python3
"""セッション記録から「進行中の作業を残して終えたターン」を機械抽出する.

Issue: Cor-Incorporated/aidd-governance#96 受入基準 (1) と (2)

  (1) 進行中の run を残してターンを終えた回数が 0 であることを、
      セッション記録から機械抽出できる
  (2) `status=in_progress` を「前進」と報告した箇所が 0 件

起点事故 (2026-08-27): 監督は Alpha CD run 33091489486 が in_progress
(success=17/25 step) の状態で「進んでいる」と報告してターンを終えた。11 分後に
CD は失敗し、ユーザーが翌朝指摘するまで 7 時間 25 分だれも気づかなかった。

--- 出力しないもの（人間ゲート） ---------------------------------------------
セッション記録はプロンプト本文を含む。本スクリプトは **件数と id と
コマンド断片だけ**を出す。ユーザー発話・アシスタント本文・添付は読むが出さない。
--report-text を付けても出るのは一致した辞書語とその前後の短い断片だけである。

--- なぜ素朴な正規表現では数えられないか（実測） ----------------------------
`gh workflow run` や `nohup` という文字列は、commit message・テスト用の
payload・ソースコードの中にも現れる。2026-09-02 の実測では、監督セッション 1 本に
対し素朴な部分一致が 4 件ヒットし、**そのすべてが偽陽性**だった（実際の起動 0 件）。

  1 件目: commit message 本文（hook の説明文）
  2 件目: テスト payload の JSON 文字列
  3 件目: Python ソース中の RUNNER 集合リテラル
  4 件目: heredoc 本文の散文

受入基準 (1) は「**0 件であること**を示せる」ことを要求している。偽陽性が残ると
0 を示せないので、`hooks/lane-launch-gate.sh` と同じ **コマンド位置判定** に加えて
**heredoc 本文の除去**まで行う。これは厳しすぎる設計ではなく、基準が要求する精度である。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import sys

# 引数をデータとして扱うコマンド。ここに現れる語はコマンドではない。
DATA_ONLY = {
    "grep",
    "egrep",
    "fgrep",
    "rg",
    "ag",
    "echo",
    "printf",
    "cat",
    "tee",
    "head",
    "tail",
    "sed",
    "awk",
    "jq",
    "less",
    "more",
}
# 引数をコマンドとして実行しうるもの。読み飛ばして先の語を見に行く。
RUNNER = {
    "env",
    "sudo",
    "doas",
    "time",
    "timeout",
    "stdbuf",
    "nice",
    "ionice",
    "setsid",
    "command",
    "exec",
    "xargs",
    "bash",
    "sh",
    "zsh",
    "dash",
    "ksh",
}
# ターンを越えて生き続ける起動の形。lane-launch-gate と同じく実行位置で判定する。
DETACH = "nohup"

_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_HEREDOC_RE = re.compile(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?")


def strip_heredoc_bodies(cmd: str) -> str:
    """データ文脈が食う heredoc 本文を落とす.

    `git commit -F - <<'EOF' … EOF` の本文は散文であって実行されない。
    一方 `python3 - <<'PY' … PY` の本文はコードなので **落とさない**。
    無条件に落とすと後者の中の起動を見落とす（protect-branches.sh が
    2026-09-02 に踏んだ欠陥と同型）。
    """
    out, delim = [], None
    for line in cmd.splitlines():
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        m = _HEREDOC_RE.search(line)
        if m:
            try:
                toks = shlex.split(line.split("<<")[0])
            except ValueError:
                toks = line.split()
            head = ""
            for t in toks:
                t = t.strip()
                if not t or t.startswith("-") or _ASSIGN_RE.match(t):
                    continue
                head = os.path.basename(t)
                break
            # git は commit message 本文を食うのでデータ扱いにする。
            if head in DATA_ONLY or head == "git":
                delim = m.group(1)
        out.append(line)
    return "\n".join(out)


def launches_in(cmd: str) -> list[str]:
    """コマンド位置で「実際に起動している」非同期作業だけを返す."""
    found: list[str] = []
    for seg in re.split(r"[;&|\n]+", strip_heredoc_bodies(cmd)):
        seg = seg.strip()
        if not seg:
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            continue
        i, detached = 0, False
        while i < len(toks) and (
            toks[i] in RUNNER or toks[i] == DETACH or _ASSIGN_RE.match(toks[i])
        ):
            if toks[i] == DETACH:
                detached = True
            i += 1
        if i >= len(toks) or toks[i] in DATA_ONLY:
            continue
        if detached:
            found.append("nohup")
            continue
        base = os.path.basename(toks[i])
        if base == "gh":
            rest = [t for t in toks[i + 1 :] if not t.startswith("-")]
            if len(rest) >= 2 and rest[0] == "workflow" and rest[1] == "run":
                found.append("gh workflow run")
            elif len(rest) >= 2 and rest[0] == "run" and rest[1] == "watch":
                found.append("gh run watch")
    return found


def resolutions_in(cmd: str) -> list[str]:
    """終端を証明する操作。conclusion の読み出しか台帳の resolve のみを数える。

    `status` だけを見る呼び出しは終端の証拠にならない（#96 の核心）ので
    数えない。
    """
    found: list[str] = []
    for seg in re.split(r"[;&|\n]+", strip_heredoc_bodies(cmd)):
        seg = seg.strip()
        if not seg:
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            continue
        i = 0
        while i < len(toks) and (toks[i] in RUNNER or _ASSIGN_RE.match(toks[i])):
            i += 1
        if i >= len(toks) or toks[i] in DATA_ONLY:
            continue
        joined = " ".join(toks[i:])
        if "async-work.sh" in joined and " resolve" in joined:
            found.append("async-work resolve")
        elif (
            os.path.basename(toks[i]) == "gh"
            and " run view" in joined
            and "conclusion" in joined
        ):
            found.append("gh run view conclusion")
    return found


# --- (2) status=in_progress を「前進」と報告した箇所 --------------------------
# **表面形マッチである。** 意味照合ではない（機械化不可 — patterns C1 / C15）。
# H3 の断定語彙辞書と同じ扱いで、warn どまり・block 禁止。
# 「in_progress を進捗として報告した」ことの近似であって、真偽ではない。
_IN_PROGRESS_RE = re.compile(r"in[_\s-]?progress|進行中", re.IGNORECASE)
_PROGRESS_CLAIM_RE = re.compile(
    r"進んでいる|順調|問題なさそう|うまくいっている|progressing|on track|looks good|going well"
)
# 同じ段落で conclusion を読んでいれば、in_progress を根拠にしていない。
# 裸の success / failure は入れない。"success=17/25 step" のような **進捗カウンタ**を
# conclusion の読み出しと誤認し、#96 の起点事故そのものの文面を見逃す（実測で踏んだ）。
_CONCLUSION_RE = re.compile(r"conclusion|完了を確認|完了を確認済")


def in_progress_claims(text: str) -> list[str]:
    """in_progress を前進の根拠にした疑いのある箇所を返す（断片のみ）."""
    hits = []
    for para in re.split(r"\n{2,}", text or ""):
        if not _IN_PROGRESS_RE.search(para):
            continue
        if not _PROGRESS_CLAIM_RE.search(para):
            continue
        if _CONCLUSION_RE.search(para):
            continue
        m = _IN_PROGRESS_RE.search(para)
        start = max(0, m.start() - 40)
        hits.append(re.sub(r"\s+", " ", para[start : m.start() + 60]))
    return hits


def is_human_prompt(rec: dict) -> bool:
    """tool_result ではない user メッセージ = 人間の発話 = ターンの開始."""
    if rec.get("type") != "user":
        return False
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return not any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in content
        )
    return False


def scan_file(path: str, want_text: bool) -> dict:
    turns: list[dict] = []
    cur: dict | None = None
    claims: list[dict] = []
    try:
        stream = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return {"turns": [], "claims": [], "unreadable": True}
    with stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if is_human_prompt(rec):
                if cur is not None:
                    turns.append(cur)
                cur = {"ts": rec.get("timestamp", ""), "launched": [], "resolved": []}
                continue
            if cur is None or rec.get("type") != "assistant":
                continue
            for blk in (rec.get("message") or {}).get("content") or []:
                if not isinstance(blk, dict):
                    continue
                if blk.get("type") == "tool_use":
                    cmd = (blk.get("input") or {}).get("command")
                    if isinstance(cmd, str) and cmd:
                        cur["launched"].extend(launches_in(cmd))
                        cur["resolved"].extend(resolutions_in(cmd))
                elif blk.get("type") == "text" and want_text:
                    for frag in in_progress_claims(blk.get("text") or ""):
                        claims.append(
                            {"ts": rec.get("timestamp", ""), "fragment": frag}
                        )
    if cur is not None:
        turns.append(cur)
    return {"turns": turns, "claims": claims, "unreadable": False}


def default_roots() -> list[str]:
    return [os.path.expanduser("~/.claude/projects")]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="#96 (1)(2) セッション記録スキャナ")
    ap.add_argument(
        "--root",
        action="append",
        default=None,
        help="走査するディレクトリ（既定: ~/.claude/projects）",
    )
    ap.add_argument("--file", action="append", default=None, help="単一ファイルを走査")
    ap.add_argument("--limit", type=int, default=50, help="新しい順に何ファイル見るか")
    ap.add_argument(
        "--report-text",
        action="store_true",
        help="(2) in_progress を前進と報告した疑いも数える",
    )
    ap.add_argument("--json", action="store_true", help="機械可読出力")
    args = ap.parse_args(argv)

    files: list[str] = list(args.file or [])
    if not files:
        for root in args.root or default_roots():
            files.extend(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
        files.sort(
            key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True
        )
        files = files[: args.limit]

    total_turns = 0
    carried: list[dict] = []
    claims: list[dict] = []
    unreadable = 0
    for path in files:
        res = scan_file(path, args.report_text)
        if res["unreadable"]:
            unreadable += 1
            continue
        for turn in res["turns"]:
            total_turns += 1
            if len(turn["launched"]) > len(turn["resolved"]):
                carried.append(
                    {
                        "file": os.path.basename(path),
                        "ts": turn["ts"],
                        "launched": turn["launched"],
                        "resolved": turn["resolved"],
                    }
                )
        claims.extend({"file": os.path.basename(path), **c} for c in res["claims"])

    out = {
        "files_scanned": len(files),
        "files_unreadable": unreadable,
        "turns": total_turns,
        # 受入基準 (1): この数が 0 であることを示せる
        "turns_ended_with_unresolved_async": len(carried),
        "detail": carried[:20],
    }
    if args.report_text:
        # 受入基準 (2): 表面形マッチ。warn どまりで、真偽の主張ではない。
        out["in_progress_progress_claims"] = len(claims)
        out["claims_detail"] = claims[:20]

    if args.json:
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    else:
        print(
            "走査ファイル: %d（読めなかった %d）" % (out["files_scanned"], unreadable)
        )
        print("検出ターン: %d" % total_turns)
        print("進行中の非同期作業を残して終えたターン: %d" % len(carried))
        for row in carried[:20]:
            print(
                "  - %s %s launched=%s resolved=%s"
                % (row["file"][:28], row["ts"][:19], row["launched"], row["resolved"])
            )
        if args.report_text:
            print(
                "in_progress を前進と報告した疑い: %d 件（表面形マッチ・warn どまり）"
                % len(claims)
            )
            for row in claims[:20]:
                print("  - %s %s" % (row["ts"][:19], row["fragment"][:80]))
    # 非ゼロ終了はしない。これは計測器であって関門ではない（#96 は測れることを求めている）。
    return 0


if __name__ == "__main__":
    sys.exit(main())
