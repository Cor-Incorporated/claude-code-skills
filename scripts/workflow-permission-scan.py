#!/usr/bin/env python3
"""step が呼ぶ GitHub API 面と job の permissions を機械照合する（aidd-governance#94）。

発端: 2026-08-27 の Grift Alpha CD 初回発射。job "Authorize exact develop head" の
step が `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` を呼ぶのに、job の
permissions は `contents: read` だけだった。YAML は妥当、actionlint も無言、push 前
26 項目ゲートは ALL GREEN。**403 が返るまで誰も知らなかった。** 権限は job の属性で、
API 呼び出しは step の属性なので、同じファイル内でも宣言と使用が離れると見落とす。

この検査器の設計原則 —

1. **判定は 5 値**。PASS/FAIL の 2 値に潰すと、判定できない範囲が PASS に混ざる。
   GRANTED / MISSING / UNDECIDABLE-PERMS / UNDECIDABLE-API / NOT-APPLICABLE。
   exit 1 になるのは MISSING だけ。UNDECIDABLE は必ず一覧に出す（隠さない）。
2. **根拠のない対応づけでは落とさない**。scripts/lib/gh-permission-map.yaml の
   `evidence` が空のエントリは MISSING を出さず UNDECIDABLE-API に落ちる。
   検査器が自前の前提で製品を裁くと、検査器自身が二重管理の発生源になる（#98）。
3. **YAML は厳格に読む**。重複キーを PyYAML の既定挙動（後勝ちで黙って通す）に
   任せない。2026-08-27 の同型事例 #1 は `yaml.safe_load` が workflow の重複キーを
   見逃し、GitHub の dispatch が HTTP 422 を返して初めて判明した（#98）。
   寛容なローカル計測器で厳格なリモートを検証してはならない。
4. **step が呼ぶスクリプトの中まで追う**。実際の API 呼び出しは
   `run: bash scripts/foo.sh` の 1 段先にいることが多い（本リポジトリの
   h5-admission がまさにそれ）。追わない検査器はこのリポジトリで 0 件を返す。

使い方:
    python3 scripts/workflow-permission-scan.py                 # 既定 .github/workflows
    python3 scripts/workflow-permission-scan.py --root /path/to/repo
    python3 scripts/workflow-permission-scan.py --format json
    python3 scripts/workflow-permission-scan.py --strict-undecidable   # 判定不能も exit 1

exit 0 = MISSING なし / exit 1 = MISSING あり / exit 2 = 検査器自身のエラー
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:  # 検査器が黙って居なくなるのを防ぐ。fail-open しない。
    sys.stderr.write(
        "workflow-permission-scan: PyYAML が無い。`python3 -m pip install pyyaml` を実行する。\n"
        "（ここで exit 0 を返すと『検査していないのに緑』になるので exit 2 で落とす）\n"
    )
    sys.exit(2)

GRANTED = "GRANTED"
MISSING = "MISSING"
UNDECIDABLE_PERMS = "UNDECIDABLE-PERMS"
UNDECIDABLE_API = "UNDECIDABLE-API"
NOT_APPLICABLE = "NOT-APPLICABLE"

LEVEL_ORDER = {"none": 0, "read": 1, "write": 2}
DEFAULT_TOKEN_EXPRS = ("github.token", "secrets.GITHUB_TOKEN")
MAX_SCRIPT_DEPTH = 3

# `${{ ... }}` のうち、URL パスで **複数セグメント**へ展開されるもの。
# github.repository は `owner/repo` の 2 セグメント。1 個の `{}` に潰すと
# セグメント数が合わず、対応表のどのパターンにも当たらなくなる。
# 表に無い式は 1 セグメント扱い（安全側 — 当たらなければ UNDECIDABLE に落ちる）。
MULTI_SEGMENT_EXPRESSIONS = {
    "github.repository": "{}/{}",
}

# シェル変数側の同じ問題。GITHUB_REPOSITORY は GitHub Actions の既定環境変数で
# 「The owner and repository name. For example, `octocat/Hello-World`.」
# （docs.github.com/en/actions/reference/workflows-and-actions/variables、2026-09-02 参照）
# = 2 セグメント。実測: これを 1 セグメント扱いにすると、スクリプト内の
# `gh api "repos/${GITHUB_REPOSITORY}/commits/$SHA/check-runs"` が
# `repos/{}/commits/{}/check-runs` に化けて #94 の欠陥を取り逃す（真理値表 A13/A14）。
# 表に無いシェル変数は 1 セグメント扱い（当たらなければ UNDECIDABLE に落ちる安全側）。
MULTI_SEGMENT_SHELL_VARS = {
    "GITHUB_REPOSITORY": "{}/{}",
}


class ScanError(Exception):
    """検査器が判定を続けられない状態。fail-open せず exit 2 に落とすために使う。"""


# --------------------------------------------------------------------------
# 1. 厳格 YAML ローダ（重複キーを黙って後勝ちにしない）
# --------------------------------------------------------------------------
class StrictLoader(yaml.SafeLoader):
    """重複マッピングキーを検出する SafeLoader。

    GitHub は重複キーのある workflow を HTTP 422 で拒否するが、PyYAML の既定は
    後勝ちで黙って通す。計測器の側が緩いと、欠陥はリモートまで隠れる（#98 同型 #1）。
    """


def _no_duplicate_keys(loader: StrictLoader, node):  # noqa: ANN001 - PyYAML API
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if key in mapping:
            mark = key_node.start_mark
            raise ScanError(
                f"duplicate YAML key {key!r} at line {mark.line + 1} column {mark.column + 1}"
            )
        mapping[key] = loader.construct_object(value_node, deep=True)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys
)


def load_yaml(path: Path):
    try:
        return yaml.load(path.read_text(encoding="utf-8"), Loader=StrictLoader)
    except ScanError as exc:
        raise ScanError(f"{path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ScanError(f"{path}: YAML parse error: {exc}") from exc


# --------------------------------------------------------------------------
# 2. permissions の解決
# --------------------------------------------------------------------------
class Perms:
    """job に効いている permissions。宣言されていない状態を None と区別して持つ。"""

    def __init__(self, default: str, explicit: dict[str, str], source: str):
        self.default = default
        self.explicit = explicit
        self.source = source

    def level(self, scope: str) -> str:
        return self.explicit.get(scope, self.default)

    def describe(self) -> str:
        if self.explicit:
            body = ", ".join(f"{k}: {v}" for k, v in sorted(self.explicit.items()))
        else:
            body = "(no scope entries)"
        return f"{{{body}}} default={self.default} from={self.source}"


def parse_permissions(node, source: str) -> Perms | None:
    """workflow / job の permissions ノードを Perms へ。未宣言は None を返す。"""
    if node is None:
        return None
    if isinstance(node, str):
        if node == "read-all":
            return Perms("read", {}, source)
        if node == "write-all":
            return Perms("write", {}, source)
        raise ScanError(f"{source}: unknown permissions shorthand {node!r}")
    if isinstance(node, dict):
        explicit = {}
        for scope, lvl in node.items():
            lvl = str(lvl)
            if lvl not in LEVEL_ORDER:
                raise ScanError(
                    f"{source}: permissions.{scope} has unknown level {lvl!r}"
                )
            explicit[str(scope)] = lvl
        return Perms("none", explicit, source)
    raise ScanError(
        f"{source}: permissions must be a string or mapping, got {type(node).__name__}"
    )


# --------------------------------------------------------------------------
# 3. API 呼び出しの抽出
# --------------------------------------------------------------------------
class Call:
    def __init__(self, kind: str, target: str, method: str, raw: str, origin: str):
        self.kind = kind  # "rest" | "gh_command" | "action" | "github_script"
        self.target = target  # 正規化済みパス / "pr view" / action 名
        self.method = method
        self.raw = raw
        self.origin = origin  # どのファイルの何行目で見つけたか

    def label(self) -> str:
        if self.kind == "rest":
            return f"{self.method} {self.target}"
        return self.target


_GH_API_RE = re.compile(r"\bgh\s+api\b(?P<args>[^\n|;&)]*)")
_GH_CMD_RE = re.compile(
    r"\bgh\s+(?P<cmd>pr|issue|run|workflow|release|repo|secret|variable|label|cache)"
    r"\s+(?P<sub>[a-z][a-z-]*)"
)
_CURL_API_RE = re.compile(
    r"(?:https://api\.github\.com|\$\{?GITHUB_API_URL\}?)/(?P<path>[^\s\"']+)"
)
_METHOD_RE = re.compile(r"(?:-X|--method)[=\s]+(?P<m>[A-Za-z]+)")
_BODY_FLAG_RE = re.compile(r"(?:^|\s)(?:-f|-F|--field|--raw-field|--input)\b")
_SCRIPT_CALL_RE = re.compile(
    r"(?:^|[\s;&|])(?:bash|sh|zsh|source|\.)\s+(?P<p>[A-Za-z0-9_./\-]+\.sh)\b"
    r"|(?:^|[\s;&|])(?P<q>\./[A-Za-z0-9_./\-]+\.sh)\b"
)
_DYNAMIC_SEG_RE = re.compile(r"\$|\{\{")


def normalize_path(raw: str) -> str:
    """API パスをセグメント単位で正規化する。動的セグメントは `{}` に潰す。

    `repos/{owner}/{repo}/commits/$SHA/check-runs`
        -> `repos/{}/{}/commits/{}/check-runs`
    """
    path = collapse_expressions(raw).strip().strip("\"'")
    path = re.sub(r"^https?://[^/]+/", "", path)
    path = path.split("?", 1)[0].lstrip("/")
    segments = []
    for seg in path.split("/"):
        if not seg:
            continue
        if _DYNAMIC_SEG_RE.search(seg) or re.fullmatch(r"\{[^}]*\}", seg):
            segments.append("{}")
        else:
            segments.append(seg)
    return "/".join(segments)


def collapse_expressions(text: str) -> str:
    """`${{ ... }}` を空白を含まないセグメント表現へ潰す。

    そのままだと式の中の空白でトークン分割が壊れ、パスが途中で切れる
    （実測: `gh api "repos/${{ github.repository }}/commits/$SHA/check-runs"` が
    `repos/{}` に化けて #94 の欠陥そのものを取り逃した）。

    `github.repository` は `owner/repo` の **2 セグメント**に展開されるので、
    1 個の `{}` に潰すとセグメント数が合わなくなる。展開後のセグメント数が
    既知の式だけ表に持ち、それ以外は 1 セグメント扱いにする。
    """

    def repl_expr(match: re.Match) -> str:
        return MULTI_SEGMENT_EXPRESSIONS.get(match.group(1).strip(), "{}")

    def repl_var(match: re.Match) -> str:
        name = match.group(1) or match.group(2)
        return MULTI_SEGMENT_SHELL_VARS.get(name, "{}")

    # `${{ ... }}` を先に潰してから `${VAR}` / `$VAR` を見る（順序が逆だと壊れる）。
    text = re.sub(r"\$\{\{(.*?)\}\}", repl_expr, text)
    return re.sub(r"\$\{(\w+)\}|\$(\w+)", repl_var, text)


def _first_positional(args: str) -> str | None:
    """`gh api` の引数列から最初の非フラグ引数（= パス）を取り出す。"""
    try:
        tokens = shlex.split(collapse_expressions(args))
    except ValueError:
        tokens = collapse_expressions(args).split()
    skip_next = False
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if tok.startswith("-"):
            if "=" not in tok and tok in (
                "-X",
                "--method",
                "-f",
                "-F",
                "--field",
                "--raw-field",
                "--input",
                "-H",
                "--header",
                "-q",
                "--jq",
                "-t",
                "--template",
            ):
                skip_next = True
            continue
        return tok
    return None


_HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


def strip_shell_data(text: str) -> str:
    """シェル本文から「データであってコマンドではない」部分を落とす。

    落とさないと、fixture を書くテストスクリプト自身が API を呼んでいることに
    なる（実測: tests/test-workflow-permission-scan.sh の中の `gh api` 文字列で
    MISSING が 6 件出た。誤検知でゲートを騒がしくすると、ゲートは殺される）。

    落とす対象は 2 つだけ:
      1. **heredoc 本文** — 呼ばれたコマンドの stdin であって、この
         スクリプトのコマンド行ではない。
      2. **変数代入の右辺** — `FOO='gh api ...'` は API を呼ばない。
         代入は宣言であって呼び出しではない。

    単引用符の除去は**しない**。`gh api 'repos/o/r/x'` は実際の呼び出しであり、
    引用符だけを根拠に落とすと本物の呼び出しが消える。
    """
    lines = text.splitlines()
    out: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = _HEREDOC_RE.search(line)
        out.append(line)
        index += 1
        if not match:
            continue
        delimiter = match.group(2)
        while index < len(lines) and lines[index].strip() != delimiter:
            index += 1
        index += 1  # 終端デリミタ行も落とす
    body = "\n".join(out)

    def blank_assignment(match: re.Match) -> str:
        rhs = match.group(0).split("=", 1)[1]
        # コマンド置換を含む代入は「データ」ではない。実行される。
        # 実測: この除外を入れないと h5-admission-check.sh の
        # `PR_BODY="$(gh pr view ...)"` が消え、本物の呼び出しを取り逃す
        # （偽陰性。偽陽性より重い）。
        if "$(" in rhs or "`" in rhs:
            return match.group(0)
        return match.group(0).split("=", 1)[0] + "=<data>"

    return re.sub(r"(?m)^\s*\w+=(?:'[^']*'|\"[^\"]*\")", blank_assignment, body)


# 引用符の状態をファイル全体で追跡して「単引用符の中はデータ」と見なす案は捨てた。
# 実測: h5-admission-check.sh の途中に現れる `sed 's#...#'` 等で状態がずれ、
# 49 行目の本物の `gh pr view` が消えた（偽陰性）。シェルには literal と code の
# 明確な境界が無く、一般解は無い。代わりに、対象ファイル自身が明示的に宣言する。
# 宣言は走査結果に必ず印字されるので、黙って消えることはない。
FIXTURES_ONLY_MARKER = "workflow-permission-scan: fixtures-only"


def extract_calls(text: str, origin: str) -> list[Call]:
    """シェル本文から API 呼び出しを抽出する。

    `text` は strip_shell_data() 済みであること。**二重に掛けてはならない** —
    strip_shell_data は冪等ではない。1 回目が heredoc の本文と終端デリミタを
    消し、開始行の `<<'PY'` だけが残るので、2 回目はその終端を見つけられず
    ファイル末尾まで飲み込む。実測: これで h5-admission-check.sh:49 の
    `gh pr view` が消え、h5-admission job の呼び出しが 3 件から 1 件に落ちた
    （偽陰性 — 検査器が何も見ていないのに緑になる、最悪の壊れ方）。
    """
    calls: list[Call] = []
    for match in _GH_API_RE.finditer(text):
        args = match.group("args")
        path = _first_positional(args)
        if path is None:
            continue
        mm = _METHOD_RE.search(args)
        if mm:
            method = mm.group("m").upper()
        else:
            # gh api --help: "The default HTTP request method is GET normally and
            # POST if any parameters were added." (gh 2.98.0 で実測)
            method = "POST" if _BODY_FLAG_RE.search(args) else "GET"
        calls.append(
            Call("rest", normalize_path(path), method, match.group(0).strip(), origin)
        )
    for match in _GH_CMD_RE.finditer(text):
        target = f"{match.group('cmd')} {match.group('sub')}"
        calls.append(Call("gh_command", target, "-", match.group(0).strip(), origin))
    for match in _CURL_API_RE.finditer(text):
        window = text[max(0, match.start() - 200) : match.end() + 200]
        mm = _METHOD_RE.search(window)
        method = mm.group("m").upper() if mm else "GET"
        calls.append(
            Call(
                "rest",
                normalize_path(match.group("path")),
                method,
                match.group(0),
                origin,
            )
        )
    return calls


def extract_script_paths(text: str) -> list[str]:
    out = []
    for match in _SCRIPT_CALL_RE.finditer(text):
        out.append(match.group("p") or match.group("q"))
    return out


def collect_from_shell(
    text: str, root: Path, origin: str, depth: int, seen: set[str], notes: list[str]
) -> list[Call]:
    """run: 本文と、そこから呼ばれるローカルスクリプトを再帰的に読む。"""
    text = strip_shell_data(text)  # heredoc 内の `bash x.sh` も実行ではない
    calls = extract_calls(text, origin)
    if depth >= MAX_SCRIPT_DEPTH:
        return calls
    for rel in extract_script_paths(text):
        target = (root / rel.lstrip("./")).resolve()
        key = str(target)
        if key in seen or not target.is_file():
            continue
        seen.add(key)
        try:
            body = target.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel_origin = os.path.relpath(target, root)
        if FIXTURES_ONLY_MARKER in body:
            # 対象ファイルが「ここの gh 呼び出しは fixture の文字列だけ」と
            # 自己申告している。走査結果に必ず出すので黙って消えることはない。
            notes.append(
                f"{rel_origin} (declared: {FIXTURES_ONLY_MARKER}) from {origin}"
            )
            continue
        calls.extend(collect_from_shell(body, root, rel_origin, depth + 1, seen, notes))
    return calls


# --------------------------------------------------------------------------
# 4. マップ照合
# --------------------------------------------------------------------------
class PermissionMap:
    def __init__(self, data: dict):
        self.rest = data.get("rest") or []
        self.gh_commands = data.get("gh_commands") or []
        self.actions = data.get("actions") or []
        self.ns = data.get("github_script_namespaces") or {}

    @staticmethod
    def _path_matches(pattern: str, actual: str) -> bool:
        p_segs = [
            ("{}" if re.fullmatch(r"\{[^}]*\}", s) else s) for s in pattern.split("/")
        ]
        a_segs = actual.split("/")
        if len(p_segs) != len(a_segs):
            return False
        # 非対称: パターン側の `{}` は何にでも当たるが、パターン側のリテラルに
        # 呼び出し側の動的セグメント `{}` を当ててはならない（中身が分からない）。
        return all(p == "{}" or p == a for p, a in zip(p_segs, a_segs))

    def lookup_rest(self, call: Call):
        path_hits = [
            e for e in self.rest if self._path_matches(e["match"], call.target)
        ]
        if not path_hits:
            dynamic = [i for i, s in enumerate(call.target.split("/")) if s == "{}"]
            reason = (
                f"対応表のどのパターンにも当たらない。動的セグメント位置={dynamic}"
                if dynamic
                else "対応表に無いパス"
            )
            return None, reason
        exact = [
            e
            for e in path_hits
            if str(e.get("method", "ANY")).upper() in ("ANY", call.method)
        ]
        if not exact:
            methods = sorted({str(e.get("method", "ANY")) for e in path_hits})
            return (
                None,
                f"path は既知だが method={call.method} が対応表に無い（既知: {methods}）",
            )
        return exact[0], ""

    def lookup_gh_command(self, call: Call):
        for entry in self.gh_commands:
            if entry["match"] == call.target:
                return entry, ""
        return None, "対応表に無い gh サブコマンド"

    def lookup_action(self, name: str):
        base = name.split("@", 1)[0]
        for entry in self.actions:
            if entry["match"] == base:
                return entry, ""
        return None, "第三者 action の API 面は静的に読めない"


# --------------------------------------------------------------------------
# 5. 判定
# --------------------------------------------------------------------------
class Finding:
    def __init__(self, workflow, job, step, call, verdict, required, granted, reason):
        self.workflow = workflow
        self.job = job
        self.step = step
        self.call = call
        self.verdict = verdict
        self.required = required
        self.granted = granted
        self.reason = reason

    def as_dict(self) -> dict:
        return {
            "workflow": self.workflow,
            "job": self.job,
            "step": self.step,
            "call": self.call.label(),
            "call_kind": self.call.kind,
            "found_in": self.call.origin,
            "verdict": self.verdict,
            "required": self.required,
            "granted": self.granted,
            "reason": self.reason,
        }


def token_is_default(env_chain: list[dict]) -> tuple[bool, str]:
    """step/job/workflow の env から実効トークンを決める。既定トークンか否かを返す。"""
    for env in env_chain:
        for key in ("GH_TOKEN", "GITHUB_TOKEN"):
            if key not in env:
                continue
            value = str(env[key])
            inner = re.sub(r"[\s{}$]", "", value)
            if any(expr.replace(" ", "") == inner for expr in DEFAULT_TOKEN_EXPRS):
                return True, value
            return False, value
    # 未設定: gh は認証できず失敗するが、permissions 照合は続ける方が安全側。
    return True, "(unset; assumed default GITHUB_TOKEN)"


def judge(
    call: Call,
    entry,
    reason: str,
    perms: Perms | None,
    default_token: bool,
    token_value: str,
) -> tuple[str, str, str, str]:
    """1 呼び出しの 5 値判定。戻り値は (verdict, required, granted, reason)。"""
    if entry is None:
        return UNDECIDABLE_API, "-", (perms.describe() if perms else "-"), reason
    if not str(entry.get("evidence", "")).strip():
        return (
            UNDECIDABLE_API,
            f"{entry['scope']}: {entry['level']}",
            perms.describe() if perms else "-",
            "対応表エントリに evidence が無いため判定を保留する",
        )
    required = f"{entry['scope']}: {entry['level']}"
    if not default_token:
        return (
            NOT_APPLICABLE,
            required,
            f"token={token_value}",
            "既定 GITHUB_TOKEN ではないので job の permissions は効かない",
        )
    if perms is None:
        return (
            UNDECIDABLE_PERMS,
            required,
            "(permissions 未宣言)",
            "workflow / job のどちらにも permissions が無い。既定はリポジトリ設定"
            "依存で、このリポジトリからは読めない",
        )
    have = perms.level(entry["scope"])
    if LEVEL_ORDER[have] >= LEVEL_ORDER[entry["level"]]:
        return GRANTED, required, perms.describe(), ""
    return (
        MISSING,
        required,
        perms.describe(),
        f"{entry['scope']} は {have} だが {entry['level']} が要る。根拠: "
        f"{' '.join(str(entry['evidence']).split())}",
    )


def _as_dict(node) -> dict:
    return {str(k): v for k, v in node.items()} if isinstance(node, dict) else {}


def scan_job(
    wf_name, job_name, job, wf_perms, wf_env, root, pmap, notes
) -> tuple[list[Finding], Perms | None]:
    perms = parse_permissions(
        job.get("permissions"), f"{wf_name}:{job_name}.permissions"
    )
    if perms is None:
        perms = wf_perms
    job_env = _as_dict(job.get("env"))
    findings: list[Finding] = []
    for index, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        label = step.get("name") or step.get("uses") or f"step[{index}]"
        env_chain = [_as_dict(step.get("env")), job_env, wf_env]
        default_token, token_value = token_is_default(env_chain)
        for call, entry, reason in _step_calls(
            step, root, wf_name, job_name, label, pmap, notes
        ):
            verdict, req, granted, why = judge(
                call, entry, reason, perms, default_token, token_value
            )
            findings.append(
                Finding(wf_name, job_name, label, call, verdict, req, granted, why)
            )
    return findings, perms


def _step_calls(step, root, wf_name, job_name, label, pmap, notes):
    """1 step が持つ (Call, map entry, reason) を列挙する。"""
    out = []
    uses = step.get("uses")
    if uses:
        entry, reason = pmap.lookup_action(str(uses))
        call = Call(
            "action", str(uses), "-", f"uses: {uses}", f"{wf_name}:{job_name}:{label}"
        )
        out.append((call, entry, reason))
        script = _as_dict(step.get("with")).get("script")
        if script:
            out.extend(
                _github_script_calls(str(script), wf_name, job_name, label, pmap)
            )
    run = step.get("run")
    if run:
        origin = f"{wf_name}:{job_name}:{label}"
        for call in collect_from_shell(str(run), root, origin, 0, set(), notes):
            if call.kind == "rest":
                entry, reason = pmap.lookup_rest(call)
            else:
                entry, reason = pmap.lookup_gh_command(call)
            out.append((call, entry, reason))
    return out


def _github_script_calls(script: str, wf_name, job_name, label, pmap):
    """actions/github-script の script 本文から github.rest.<ns>.<method> を拾う。

    namespace → スコープの推定は evidence を持たないので、必ず UNDECIDABLE に落ちる
    （entry=None で返す）。それでも一覧には出す — 隠すのが一番悪い。
    """
    out = []
    for match in re.finditer(r"github\.rest\.(\w+)\.(\w+)", script):
        ns, method = match.group(1), match.group(2)
        scope = pmap.ns.get(ns)
        hint = f"github-script github.rest.{ns}.{method}"
        reason = (
            f"推定スコープ {scope}（method 名からの read/write 推定込み）は "
            "evidence を持たないため判定しない"
            if scope
            else f"namespace {ns} は対応表に無い"
        )
        out.append(
            (
                Call(
                    "github_script",
                    hint,
                    "-",
                    match.group(0),
                    f"{wf_name}:{job_name}:{label}",
                ),
                None,
                reason,
            )
        )
    return out


def scan(root: Path, workflows: Path, pmap: PermissionMap):
    findings: list[Finding] = []
    inventory: list[dict] = []
    notes: list[str] = []
    files = sorted(p for p in workflows.glob("*.y*ml") if p.is_file())
    for path in files:
        doc = load_yaml(path)
        if not isinstance(doc, dict):
            raise ScanError(f"{path}: top level is not a mapping")
        wf_name = path.name
        wf_perms = parse_permissions(doc.get("permissions"), f"{wf_name}.permissions")
        wf_env = _as_dict(doc.get("env"))
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            job_findings, perms = scan_job(
                wf_name, str(job_name), job, wf_perms, wf_env, root, pmap, notes
            )
            findings.extend(job_findings)
            inventory.append(
                {
                    "workflow": wf_name,
                    "job": str(job_name),
                    "permissions": perms.describe() if perms else "(未宣言)",
                    "api_calls": len(job_findings),
                }
            )
    return findings, inventory, [p.name for p in files], notes


# --------------------------------------------------------------------------
# 6. 出力
# --------------------------------------------------------------------------
ORDER = [MISSING, UNDECIDABLE_PERMS, UNDECIDABLE_API, NOT_APPLICABLE, GRANTED]


def render_text(findings, inventory, files, notes) -> str:
    lines = [
        "workflow-permission-scan — step の API 面 ↔ job の permissions (aidd-governance#94)",
        f"走査対象 workflow: {len(files)} 本 {files}",
        "",
        "--- job インベントリ（呼び出し 0 件の job も必ず出す。#97 の「先に全列挙」）---",
    ]
    for row in inventory:
        lines.append(
            f"  {row['workflow']} :: {row['job']}"
            f" | permissions={row['permissions']} | calls={row['api_calls']}"
        )
    if notes:
        lines += ["", "--- 追跡をやめたスクリプト（対象ファイルの自己申告）---"]
        lines += [f"  {n}" for n in notes]
    counts = {v: sum(1 for f in findings if f.verdict == v) for v in ORDER}
    lines += [
        "",
        "--- 判定（5 値。exit 1 になるのは MISSING だけ）---",
        "  " + " / ".join(f"{v}={counts[v]}" for v in ORDER),
        "",
    ]
    for verdict in ORDER:
        rows = [f for f in findings if f.verdict == verdict]
        if not rows:
            continue
        lines.append(f"[{verdict}] {len(rows)} 件")
        for f in rows:
            lines.append(f"  {f.workflow} :: {f.job} :: {f.step}")
            lines.append(
                f"    call     : {f.call.label()}   (found in {f.call.origin})"
            )
            lines.append(f"    required : {f.required}")
            lines.append(f"    granted  : {f.granted}")
            if f.reason:
                lines.append(f"    reason   : {f.reason}")
        lines.append("")
    return "\n".join(lines)


def append_ledger(findings: list[Finding]) -> None:
    """block したことを防御台帳へ 1 行ずつ残す（ADR-006 入場料 4）。

    書式と既定パスは scripts/h5-admission-check.sh の append_h5_block に合わせる。
    台帳が無いと「90 日発火ゼロ」を測れず、退役条件（入場料 6）が判定できない。
    台帳書き込みの失敗でゲートの判定を変えてはならないので、例外は握り潰す。
    """
    path = Path(
        os.environ.get(
            "WPS_LEDGER_PATH",
            str(Path.home() / ".claude" / "hooks" / "ledger" / "guard-ledger.jsonl"),
        )
    ).expanduser()
    source = os.environ.get("AIDD_LEDGER_SOURCE", "real")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            for finding in findings:
                handle.write(
                    json.dumps(
                        {
                            "ts": stamp,
                            "component": "workflow-permission-scan",
                            "event": "block",
                            "rule": finding.verdict,
                            "detail": (
                                f"{finding.workflow}:{finding.job} "
                                f"call={finding.call.label()} required={finding.required} "
                                f"granted={finding.granted}"
                            ),
                            "source": source,
                            "agent": "ci",
                        },
                        ensure_ascii=False,
                        # h5-admission-check.sh の append_h5_block と同じ compact 形式
                        separators=(",", ":"),
                    )
                    + "\n"
                )
    except OSError:
        pass


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--root", default=".", help="リポジトリルート（スクリプト追跡の基点）"
    )
    ap.add_argument("--workflows", default=None, help="既定 <root>/.github/workflows")
    ap.add_argument(
        "--map", default=None, help="既定 <script dir>/lib/gh-permission-map.yaml"
    )
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument(
        "--strict-undecidable",
        action="store_true",
        help="UNDECIDABLE-* も exit 1 にする",
    )
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    workflows = (
        Path(args.workflows).resolve()
        if args.workflows
        else root / ".github" / "workflows"
    )
    map_path = (
        Path(args.map)
        if args.map
        else Path(__file__).resolve().parent / "lib" / "gh-permission-map.yaml"
    )
    try:
        if not workflows.is_dir():
            raise ScanError(f"workflows ディレクトリが無い: {workflows}")
        pmap = PermissionMap(load_yaml(map_path))
        findings, inventory, files, notes = scan(root, workflows, pmap)
    except ScanError as exc:
        sys.stderr.write(f"workflow-permission-scan: ERROR: {exc}\n")
        return 2

    if args.format == "json":
        print(
            json.dumps(
                {
                    "files": files,
                    "inventory": inventory,
                    "skipped_fixture_files": notes,
                    "findings": [f.as_dict() for f in findings],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print(render_text(findings, inventory, files, notes))

    blocking = [f for f in findings if f.verdict == MISSING]
    if args.strict_undecidable:
        blocking += [f for f in findings if f.verdict.startswith("UNDECIDABLE")]
    if blocking:
        append_ledger(blocking)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
