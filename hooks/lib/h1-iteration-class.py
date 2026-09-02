#!/usr/bin/env python3
"""H1 反復の意味分類 — 固定反復上限を「同一失敗」と「意味進捗」で分離する.

Issue: Cor-Incorporated/aidd-governance#87
Spec : design/harness-spec.md "### H1." / design/ops/harness/h1-iteration-semantics.md

起点事故 (2026-08-23, Grift Nagi UAT #2049):
    固定 3 反復の契約で 3 つの異なる counterexample を順に RED→GREEN 化した直後、
    独立 review が固定 scope 内の新しい P1 を発見した。契約上は 3/3 到達のため
    通常 STOP した。同一失敗ループではなく oracle が強化された直後の停止であり、
    「後段の反証を省略した方が早く進む」という逆インセンティブを生んだ。

--- この装置が実際に判定するもの（過大主張しない） -------------------------------
本モジュールは**純関数**である。反復 1 件を記述した宣言レコードを受け取り、
(fingerprint, classification, transition) を返す。判定材料は宣言された値だけで
あり、次のものは *観測していない*:

  - 反例が本当に再現するか        （red_evidence は文字列として存在検査のみ）
  - invariant が本当に違反されたか（意味照合は機械化不可 — patterns C1）
  - scope 宣言が誠実か            （requirement_inventory は申告値）

つまり本装置が強制するのは「宣言の一貫性」であって「宣言の真実性」ではない。
真実性は人間のサンプリングと逆方向検証（P5）が持つ。H8 の宣言形式強制と同じ
適用限界であり、それを超える主張をしてはならない。

--- fingerprint が意図的に無視する入力 ------------------------------------------
#87 の反証 3・4 は「文言差」と「fixture 分割」で反復予算がリセットされることを
禁じている。したがって fingerprint は次を **構造的に**（実装の努力目標ではなく
入力の分離として）除外する:

    error_message  — 例外文・スタックトレース・アサート出力
    fixtures       — テストファイル名の一覧
    volume         — PR 数 / LOC / tool call 数 / review 件数

これらは記録には残るが、ハッシュ入力には一切入らない。呼び出し側が反例欄へ
エラー文を詰め込む逃げ道は数字列の正規化（下記）で塞ぐ。

--- 数字の正規化 ---------------------------------------------------------------
最小反例中の数字列は `#` へ潰す。"6/6 markers ACCEPTED" と
"12/12 markers ACCEPTED" は同一の意味的失敗であり、件数が増えただけで新しい
反証にはならない（#87 反証 8 の一般形）。これは意図的な情報破棄であって
バグではない。件数そのものが不変条件である失敗（"N=1 でのみ壊れる"）は
invariant 欄に書くこと。

--- 3 値遷移 -------------------------------------------------------------------
    CONTINUE         宣言済み epoch 内で予算が残る
    REBASE_REQUIRED  新しい反証が固定 scope 内・固定 close target・再現可能な
                     RED だが epoch 上限へ到達。**完了ではない・Issue close 不可**
    STOP             同一失敗の無進捗 / scope 拡張 / security・不可逆 / epoch 枯渇

REBASE_REQUIRED は「無制限再開」ではない。事前承認済み recovery epoch が
残っている場合だけ epoch を 1 つ消費して反復カウンタを再基準化する。
消費後の epoch で同一 fingerprint が再発したら hard STOP する。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from typing import Any

SCHEMA = "h1-iteration-semantics/v1"

# 分類ラベル（#87「反復を意味分類する」表）
SAME_FAILURE = "same_failure"
NOVEL = "novel_counterexample"
SCOPE_EXPANSION = "scope_expansion"
VERIFICATION_ONLY = "verification_only"
SECURITY = "security_or_irreversible"

CONTINUE = "CONTINUE"
REBASE_REQUIRED = "REBASE_REQUIRED"
STOP = "STOP"

# 既定の epoch 上限 = 元の epoch + recovery 1 回。#87 反証 9（recovery epoch を
# 無制限に追加する → RED）を数値で塞ぐ。
DEFAULT_MAX_EPOCHS = 2

# 同一 fingerprint がこの回数に達したら、反復上限に余裕があっても STOP する
# （#87 反証 1）。値 3 は H1 既存の「同一コマンドまたは同一エラーの反復 ≥3」
# （hooks/codex/h1-stall-runtime.sh の SAME_CMD_THRESHOLD）と同じ根拠であり、
# 片方だけ動かしてはならない。
SAME_FAILURE_THRESHOLD = 3

# fingerprint から構造的に除外する欄。ここに載っている限り、値が何であれ
# ハッシュ入力に到達しない（#87 反証 3・4）。
FINGERPRINT_EXCLUDED = (
    "error_message",
    "fixtures",
    "volume",
    "notes",
    "elapsed_sec",
    "cost_usd",
)

_WS_RE = re.compile(r"\s+")
_DIGITS_RE = re.compile(r"\d+")
_PUNCT_RE = re.compile(r"[\s\.\,\;\:\!\?\-_/\\\"'`()\[\]{}]+$")

# 「量」だけを根拠にした novelty 主張を弾く（#87 反証 8）。red_evidence が
# これらの語と数字しか含まない場合、再現可能な RED の記述とは認めない。
_VOLUME_ONLY_RE = re.compile(
    r"^(?:[\W\d]|(?:pr|prs|pull|request|requests|loc|line|lines|diff|added|removed"
    r"|tool|calls|call|review|reviews|comment|comments|commit|commits|file|files"
    r"|count|total|件|行|本|回|個|数)\b|\s)*$",
    re.IGNORECASE,
)


def _norm(text: Any) -> str:
    """fingerprint 入力の正規化。大小・空白・末尾句読点・数字を潰す。"""
    value = "" if text is None else str(text)
    value = _WS_RE.sub(" ", value).strip().lower()
    value = _DIGITS_RE.sub("#", value)
    return _PUNCT_RE.sub("", value)


def fingerprint(record: dict) -> str:
    """「違反した不変条件・oracle・最小反例」の組だけから求める.

    error_message / fixtures / volume は引数に取らない。呼び出し側が渡しても
    到達しないことがこの関数の契約である（#87 反証 3・4）。
    """
    parts = [
        _norm(record.get("invariant")),
        _norm(record.get("oracle_id")),
        _norm(record.get("counterexample")),
    ]
    payload = "\x1f".join(parts)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:32]


def _is_volume_only(evidence: Any) -> bool:
    text = "" if evidence is None else str(evidence).strip()
    if not text:
        return True
    return bool(_VOLUME_ONLY_RE.match(text))


def _truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    return bool(value)


def _semantics_defaults(record: dict) -> dict:
    return {
        "schema": SCHEMA,
        "epoch": 1,
        "max_epochs": DEFAULT_MAX_EPOCHS,
        "recovery_epoch_preapproved": False,
        "close_target": record.get("close_target", ""),
        "reserved_successor": record.get("reserved_successor", ""),
        "requirement_inventory": list(record.get("requirement_inventory") or []),
        "fingerprint_counts": {},
        "epoch_fingerprints": [],
        "implementation_iterations": 0,
        "max_iterations": 0,
        "transition": CONTINUE,
        "classification": "",
        "history": [],
    }


def classify(record: dict, state: dict | None) -> dict:
    """反復 1 件を分類して 3 値遷移を返す。state は非破壊で扱う。

    優先順位は #87「反復を意味分類する」表の重さの順であり、入れ替えてはならない。
    security_or_irreversible が最優先なのは、進捗の有無と無関係に即時停止する
    ためである（反証 6）。
    """
    sem = _semantics_defaults(record)
    if state:
        for key, value in state.items():
            sem[key] = value
    sem.setdefault("history", [])

    fp = fingerprint(record)
    counts = dict(sem.get("fingerprint_counts") or {})
    epoch_seen = list(sem.get("epoch_fingerprints") or [])
    epoch = int(sem.get("epoch") or 1)
    max_epochs = int(sem.get("max_epochs") or DEFAULT_MAX_EPOCHS)
    max_iter = int(record.get("max_iterations") or sem.get("max_iterations") or 0)
    impl_iters = int(sem.get("implementation_iterations") or 0)

    reasons: list[str] = []
    granted_rebase = False

    # --- 1. security / 不可逆 — 進捗の有無に関係なく即時 STOP（反証 6） ---------
    if _truthy(record.get("security_or_irreversible")):
        classification, transition = SECURITY, STOP
        reasons.append(
            "security/不可逆条件の申告あり: %s"
            % (record.get("security_detail") or "detail 未記載")
        )

    # --- 2. 実装変更なし = verification_only。実装反復へ算入しない --------------
    elif not _truthy(record.get("implementation_changed")):
        classification, transition = VERIFICATION_ONLY, CONTINUE
        reasons.append("実装変更なし: 実装反復カウンタへ算入しない")

    # --- 3. scope 拡張 — close target / reserved successor / インベントリ -------
    #     rebase 前後で close target が変わることも同じ経路で捕まる（反証 7）。
    else:
        drift = _scope_drift(record, sem)
        if drift:
            classification, transition = SCOPE_EXPANSION, STOP
            reasons.extend(drift)
        else:
            impl_iters += 1
            occurrences = int(counts.get(fp, 0)) + 1
            counts[fp] = occurrences
            repeat_in_epoch = fp in epoch_seen
            volume_only = _is_volume_only(record.get("red_evidence"))
            over_cap = bool(max_iter) and impl_iters > max_iter

            if occurrences > 1:
                # --- 4. 同一 fingerprint = same_failure ------------------------
                classification = SAME_FAILURE
                reasons.append(
                    "既知 fingerprint %s の再発 (%d 回目)" % (fp[:12], occurrences)
                )
                if occurrences >= SAME_FAILURE_THRESHOLD:
                    # 反復上限に余裕があっても、同一失敗の反復は無進捗である。
                    transition = STOP
                    reasons.append(
                        "同一 fingerprint が %d 回（閾値 %d）: 無進捗として STOP"
                        % (occurrences, SAME_FAILURE_THRESHOLD)
                    )
                elif epoch > 1 and repeat_in_epoch:
                    # rebase 後の epoch で同一失敗が反復 → hard STOP。
                    transition = STOP
                    reasons.append(
                        "rebase 後 epoch %d で同一失敗が反復: hard STOP" % epoch
                    )
                elif over_cap:
                    transition = STOP
                    reasons.append(
                        "反復 %d/%d 超過かつ同一失敗: 予算再基準化の対象外"
                        % (impl_iters, max_iter)
                    )
                else:
                    transition = CONTINUE
            elif volume_only:
                # --- 反証 8: 量だけを根拠に novelty を主張させない --------------
                classification = SAME_FAILURE
                reasons.append(
                    "red_evidence が量的指標のみ（PR 数・LOC・tool call 数・review 件数）: "
                    "再現可能な RED の記述と認めない"
                )
                transition = STOP if over_cap else CONTINUE
            else:
                # --- 5. 新 fingerprint・固定 scope 内・再現可能な RED -----------
                classification = NOVEL
                reasons.append("新 fingerprint %s（固定 scope 内）" % fp[:12])
                if not over_cap:
                    transition = CONTINUE
                elif epoch >= max_epochs:
                    # --- 反証 9: recovery epoch を無制限に足させない ------------
                    transition = STOP
                    reasons.append(
                        "epoch %d/%d 枯渇: これ以上の再基準化は owner decision"
                        % (epoch, max_epochs)
                    )
                elif _truthy(sem.get("recovery_epoch_preapproved")):
                    # 事前承認済み recovery epoch を 1 つ消費して再基準化する。
                    transition = CONTINUE
                    granted_rebase = True
                    epoch += 1
                    impl_iters = 0
                    epoch_seen = []
                    sem["recovery_epoch_preapproved"] = False
                    reasons.append(
                        "事前承認済み recovery epoch を消費し epoch %d へ再基準化"
                        % epoch
                    )
                else:
                    # 事前承認がなければ supervisor が同じ条件で一度だけ rebase する。
                    transition = REBASE_REQUIRED
                    reasons.append(
                        "反復 %d/%d 到達だが意味進捗: supervisor の rebase 承認が要る"
                        % (impl_iters, max_iter)
                    )

    if classification not in (VERIFICATION_ONLY, SECURITY) and fp not in epoch_seen:
        epoch_seen.append(fp)

    sem["epoch"] = epoch
    sem["max_epochs"] = max_epochs
    sem["fingerprint_counts"] = counts
    sem["epoch_fingerprints"] = epoch_seen
    sem["implementation_iterations"] = impl_iters
    sem["max_iterations"] = max_iter
    sem["classification"] = classification
    sem["transition"] = transition
    # hooks/codex/h1-stall-runtime.sh の subject_of() が台帳行へ載せる欄。
    sem["last_fingerprint"] = fp
    sem["last_oracle_id"] = record.get("oracle_id", "")
    sem["close_target"] = record.get("close_target", "") or sem.get("close_target", "")
    sem["reserved_successor"] = record.get("reserved_successor", "") or sem.get(
        "reserved_successor", ""
    )
    if record.get("requirement_inventory"):
        sem["requirement_inventory"] = list(record["requirement_inventory"])
    sem["updated_ts"] = int(time.time())

    verdict = {
        "schema": SCHEMA,
        "failure_fingerprint": fp,
        "oracle_id": record.get("oracle_id", ""),
        "classification": classification,
        "epoch": epoch,
        "close_target": sem["close_target"],
        "reserved_successor": sem["reserved_successor"],
        "transition": transition,
        "rebase_granted": granted_rebase,
        "implementation_iterations": impl_iters,
        "max_iterations": max_iter,
        # 反証 10: REBASE_REQUIRED を通常完了・Issue closeable として扱わせない。
        # この 2 欄は判定結果から機械的に導出され、呼び出し側が上書きできない。
        "completion": False,
        "issue_closeable": False,
        "reasons": reasons,
    }
    sem["history"] = (
        list(sem.get("history") or [])
        + [
            {
                "ts": sem["updated_ts"],
                "fingerprint": fp,
                "classification": classification,
                "transition": transition,
                "epoch": epoch,
            }
        ]
    )[-50:]
    return {"verdict": verdict, "semantics": sem}


def _scope_drift(record: dict, sem: dict) -> list[str]:
    """close target / reserved successor / 要求インベントリ外の逸脱を列挙する。

    #87 反証 5（close target または要求インベントリ外の finding）と
    反証 7（rebase 前後で close target と reserved successor が変わる）の両方が
    ここを通る。空欄は「未宣言」であって「変更」ではないので逸脱に数えない。
    """
    drift: list[str] = []
    for field in ("close_target", "reserved_successor"):
        declared = (sem.get(field) or "").strip()
        incoming = (record.get(field) or "").strip()
        if declared and incoming and declared != incoming:
            drift.append("%s が変化: %s -> %s" % (field, declared, incoming))
    inventory = [
        str(x).strip()
        for x in (sem.get("requirement_inventory") or [])
        if str(x).strip()
    ]
    requirement = (record.get("requirement") or "").strip()
    if inventory and requirement and requirement not in inventory:
        drift.append("要求インベントリ外の finding: %s" % requirement)
    return drift


# --- 報告文の検査（#87 反証 10 を文字列側でも機械化する） -----------------------
# REBASE_REQUIRED は「通常完了」でも「Issue close 可」でもない。報告テキストが
# 完了語彙を含みながら遷移が REBASE_REQUIRED である場合を検出する。
# H3 と同じく表面形マッチなので **警告用の検出器**であり、意味照合ではない。
_COMPLETION_RE = re.compile(
    r"(?:\bcompleted?\b|\bdone\b|\bclos(?:e|ed|ing)\b|\bresolv(?:e|ed)\b"
    r"|完了|完遂|クローズ|close 可|終了しました)",
    re.IGNORECASE,
)


def report_violations(transition: str, text: str) -> list[str]:
    if transition != REBASE_REQUIRED:
        return []
    hits = sorted({m.group(0) for m in _COMPLETION_RE.finditer(text or "")})
    if not hits:
        return []
    return [
        "transition=REBASE_REQUIRED の報告に完了語彙が含まれる: %s" % ", ".join(hits)
    ]


def _load_json(path: str | None) -> dict:
    if not path or path == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(path, encoding="utf-8") as handle:
                raw = handle.read()
        except OSError:
            return {}
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def _read_state(path: str | None, key: str) -> tuple[dict, dict]:
    """(全体 state, semantics 部分) を返す。H1 の state ファイルへ相乗りする。"""
    if not path:
        return {}, {}
    blob = _load_json(path)
    sub = blob.get(key)
    return blob, sub if isinstance(sub, dict) else {}


def _write_state(path: str, blob: dict, key: str, sem: dict) -> None:
    blob[key] = sem
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(blob, handle, ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="H1 反復の意味分類 (#87)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    cls = sub.add_parser("classify", help="反復レコードを分類し 3 値遷移を返す")
    cls.add_argument("--record", default="-", help="レコード JSON のパス (既定: stdin)")
    cls.add_argument(
        "--state", default=None, help="H1 state ファイル。相乗りで更新する"
    )
    cls.add_argument("--state-key", default="h1_semantics")
    cls.add_argument("--dry-run", action="store_true", help="state を書き換えない")

    fp = sub.add_parser("fingerprint", help="fingerprint だけを出力する")
    fp.add_argument("--record", default="-")

    rep = sub.add_parser(
        "check-report", help="REBASE_REQUIRED の報告に完了語彙がないか検査"
    )
    rep.add_argument("--state", required=True)
    rep.add_argument("--state-key", default="h1_semantics")
    rep.add_argument("--report", default="-", help="報告テキストのパス (既定: stdin)")

    args = parser.parse_args(argv)

    if args.cmd == "fingerprint":
        print(fingerprint(_load_json(args.record)))
        return 0

    if args.cmd == "check-report":
        _, sem = _read_state(args.state, args.state_key)
        if args.report == "-":
            text = sys.stdin.read()
        else:
            try:
                with open(args.report, encoding="utf-8") as handle:
                    text = handle.read()
            except OSError:
                text = ""
        violations = report_violations(str(sem.get("transition") or ""), text)
        for line in violations:
            print(line, file=sys.stderr)
        return 1 if violations else 0

    record = _load_json(args.record)
    blob, sem_in = _read_state(args.state, args.state_key)
    result = classify(record, sem_in)
    # rebase を granted した瞬間の H1 ランタイム反復カウンタを基準線として控える。
    # hooks/codex/h1-stall-runtime.sh はこの差分で上限判定するので、新 epoch の
    # 反復だけが数えられる。classify() を純関数のまま保つため、state blob に
    # 触れるこの結合だけを CLI 層に置いている。
    if result["verdict"]["rebase_granted"]:
        try:
            result["semantics"]["iteration_baseline"] = max(
                0, int(blob.get("iterations") or 0)
            )
        except (TypeError, ValueError):
            result["semantics"]["iteration_baseline"] = 0
    if args.state and not args.dry_run:
        try:
            _write_state(args.state, blob, args.state_key, result["semantics"])
        except OSError as exc:
            print("state 書き込み失敗: %s" % exc, file=sys.stderr)
            return 2
    print(json.dumps(result["verdict"], ensure_ascii=False, sort_keys=True))
    # STOP / REBASE_REQUIRED は非ゼロで返し、呼び出し側のシェルが素通しできない
    # ようにする。CONTINUE のみ 0。
    return {CONTINUE: 0, REBASE_REQUIRED: 3, STOP: 4}.get(
        result["verdict"]["transition"], 4
    )


if __name__ == "__main__":
    sys.exit(main())
