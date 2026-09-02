#!/usr/bin/env python3
"""pair2 の else を消す片側変異を注入したコピーを作る（#351 の反証用）。

else を消すと pair2 は配備先の無い環境で無言に戻る。メタテストの節 8（経験的
implemented==emitted）と節 9（構造照合）の**両方**がそれを検出できなければ、
NOTE から FAIL への格上げは効いていない。

exit: 0 = 注入した / 2 = 対象が動いていて注入できなかった（テストではなく注入を直す）
"""
import sys

OLD = "\n".join([
    "if not settings_path.is_file():",
    '    skip("pair2 skipped (no local deploy settings.json)")',
    "else:",
])
NEW = "if settings_path.is_file():"


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    if OLD not in text:
        print("MUTATION-TARGET-MOVED: pair2 else block not found", file=sys.stderr)
        return 2
    open(dst, "w", encoding="utf-8").write(text.replace(OLD, NEW, 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
