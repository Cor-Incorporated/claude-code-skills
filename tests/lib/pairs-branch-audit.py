#!/usr/bin/env python3
"""分岐の片側だけが pair を出す形（無言 pair の温床）を AST で検出する。

aidd-governance の #351。経験的な implemented==emitted 照合は「その環境で出たか」
しか見ないため、ガードが repo ファイルの存在で現行環境では常に成立する pair
（pair5 がそうだった）を捕まえられない。ここは構造で見る。

入力: 環境変数 PAIRS_FILE = tests/test-pairs-link.sh
出力: HOLE 行（あれば）と COUNT 行
exit: 0 = 走査できた（COUNT が 0 とは限らない） / 2 = 走査できなかった
"""
import ast
import os
import re
import sys

MARKER = "python3 - \"$ROOT\" <<'PY'\n"
EMIT = {"ok", "skip", "bad"}


def pairs_emitted(nodes) -> set:
    """このノード列が出す pair 番号の集合。"""
    found = set()
    for node in nodes:
        for sub in ast.walk(node):
            if not (
                isinstance(sub, ast.Call)
                and isinstance(sub.func, ast.Name)
                and sub.func.id in EMIT
            ):
                continue
            for arg in ast.walk(sub):
                texts = []
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    texts.append(arg.value)
                elif isinstance(arg, ast.JoinedStr):
                    texts += [
                        v.value
                        for v in arg.values
                        if isinstance(v, ast.Constant) and isinstance(v.value, str)
                    ]
                for t in texts:
                    m = re.match(r"pair(\d+)", t)
                    if m:
                        found.add(int(m.group(1)))
    return found


def main() -> int:
    path = os.environ.get("PAIRS_FILE")
    if not path:
        print("EXTRACT-FAILED: PAIRS_FILE not set", file=sys.stderr)
        return 2
    src = open(path, encoding="utf-8").read()
    if MARKER not in src:
        # 抽出できないなら黙って通さない（検査していないのに緑を作らない）
        print("EXTRACT-FAILED: python heredoc marker not found", file=sys.stderr)
        return 2
    body = src.split(MARKER, 1)[1].rsplit("\nPY\n", 1)[0]
    try:
        tree = ast.parse(body)
    except SyntaxError as exc:
        print(f"EXTRACT-FAILED: embedded python does not parse: {exc}", file=sys.stderr)
        return 2

    holes = []
    for node in tree.body:  # トップレベルの if だけを見る
        if not isinstance(node, ast.If):
            continue
        missing = pairs_emitted(node.body) - pairs_emitted(node.orelse)
        if missing:
            holes.append((node.lineno, sorted(missing), ast.unparse(node.test)[:60]))

    for lineno, pl, cond in holes:
        pairs = ", ".join(f"pair{n}" for n in pl)
        print(f"HOLE line {lineno}: {pairs} emitted in body but not in else -- if {cond}")
    print(f"COUNT {len(holes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
