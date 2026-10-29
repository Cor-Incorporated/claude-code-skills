#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/post-lint-format.sh
# post-lint-format.sh が、編集していない行を書き換えないことを ruff の実物で検査する。
#
# 起点 (2026-10-29 ai-cluster): ruff 設定の無い repo で test_judge_f64.py を Edit した直後、
# PostToolUse の ruff format が既定 88 桁でファイル全体を整形し、レーンは
# git checkout -- で戻して編集を当て直した。
#
# 規則: 書き込み系 (format / --fix) は (1) プロジェクトがその道具を宣言していて
# (2) コミット済みの版が既に clean なときだけ走る。新規 (untracked) は (2) を満たす。
#
# 反証可能性: HOOK=<旧版> で流すと「設定なし」「HEAD が未整形」の 2 件が red になる。
#   git show origin/develop:hooks/post-lint-format.sh > /tmp/old.sh
#   HOOK=/tmp/old.sh bash tests/test-post-lint-format.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK:-$ROOT/hooks/post-lint-format.sh}"

pass=0
fail=0
skip=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

# A mise shim for ruff fails (after ~2 s, past the hook's 2 s timeout) in a
# directory where mise has not activated it, which is every temp repo below.
# Use a ruff binary that answers --version quickly and put it first on PATH.
RUFF_BIN=""
for cand in $(type -ap ruff 2>/dev/null) "$HOME"/.local/share/mise/installs/python/*/bin/ruff; do
  [[ -x "$cand" ]] || continue
  if (cd "${TMPDIR:-/tmp}" && timeout 1 "$cand" --version >/dev/null 2>&1); then
    RUFF_BIN="$cand"
    break
  fi
done
if [[ -z "$RUFF_BIN" ]] || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: no working ruff binary or jq"
  echo "---"
  echo "pass=0 fail=0 skip=1"
  exit 0
fi
RUFF_DIR="$(dirname "$RUFF_BIN")"
export PATH="$RUFF_DIR:$PATH"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# 既定 88 桁でも、設定した 120 桁でも ruff format が触る行 (引用符・空白) と、
# 88 桁を超えるが 120 桁には収まる行を持つ。
UNFORMATTED='import os
x = {  '"'"'a'"'"':1 }
def f(a,b):
    return os.path.join(a, b, "this-is-a-fairly-long-segment-name", "and-another-long-one-x")
'

new_repo() { # $1 = dir
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name t
}

run_hook() { # $1 = file
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" >/dev/null 2>&1
}

edit_one_line() { # $1 = file: append one new, unformatted line (the "edit")
  printf 'y = [1,2 ,3]\n' >>"$1"
}

# 1. 設定なし + HEAD 未整形 → 編集後も 1 バイトも変えない
R="$SB/r1"; new_repo "$R"
printf '%s' "$UNFORMATTED" >"$R/test_judge.py"
git -C "$R" add -A && git -C "$R" commit -qm init
edit_one_line "$R/test_judge.py"
before="$(shasum "$R/test_judge.py")"
run_hook "$R/test_judge.py"
[[ "$(shasum "$R/test_judge.py")" == "$before" ]] && ok "no ruff config → the file is left exactly as edited" \
  || bad "no config must not reformat" "$(git -C "$R" diff --stat)"

# 2. 設定あり + HEAD 未整形 → 書き換えない (全体整形が無関係な行に及ぶ)
R="$SB/r2"; new_repo "$R"
printf '[tool.ruff]\nline-length = 120\n' >"$R/pyproject.toml"
printf '%s' "$UNFORMATTED" >"$R/mod.py"
git -C "$R" add -A && git -C "$R" commit -qm init
edit_one_line "$R/mod.py"
before="$(shasum "$R/mod.py")"
run_hook "$R/mod.py"
[[ "$(shasum "$R/mod.py")" == "$before" ]] && ok "config but HEAD not ruff-clean → no rewrite" \
  || bad "dirty HEAD must not reformat" "$(git -C "$R" diff)"

# 3. 設定あり + HEAD clean → 整形する。変わるのは編集した行だけ
R="$SB/r3"; new_repo "$R"
printf '[tool.ruff]\nline-length = 120\n' >"$R/pyproject.toml"
printf '%s' "$UNFORMATTED" >"$R/mod.py"
(cd "$R" && ruff format -q mod.py && ruff check -q --fix mod.py) >/dev/null 2>&1
git -C "$R" add -A && git -C "$R" commit -qm init
edit_one_line "$R/mod.py"
run_hook "$R/mod.py"
changed="$(git -C "$R" diff -U0 mod.py | grep -E '^[+-][^+-]' | sort)"
if [[ "$changed" == "+y = [1, 2, 3]" ]]; then
  ok "config + clean HEAD → only the edited line is formatted"
else
  bad "clean HEAD formatting" "diff lines: $changed"
fi

# 4. untracked の新規ファイル (設定あり) → 整形する
R="$SB/r4"; new_repo "$R"
printf '[tool.ruff]\nline-length = 120\n' >"$R/pyproject.toml"
git -C "$R" add -A && git -C "$R" commit -qm init
printf 'z = {  "k":1 }\n' >"$R/new_mod.py"
run_hook "$R/new_mod.py"
[[ "$(cat "$R/new_mod.py")" == 'z = {"k": 1}' ]] && ok "new untracked file under a ruff config is formatted" \
  || bad "untracked file" "$(cat "$R/new_mod.py")"

# 5. pyproject.toml はあるが ruff の節が無い → 宣言ではない
R="$SB/r5"; new_repo "$R"
printf '[project]\nname = "x"\n' >"$R/pyproject.toml"
git -C "$R" add -A && git -C "$R" commit -qm init
printf 'z = {  "k":1 }\n' >"$R/new_mod.py"
run_hook "$R/new_mod.py"
[[ "$(cat "$R/new_mod.py")" == 'z = {  "k":1 }' ]] && ok "pyproject.toml without [tool.ruff] does not count as a ruff config" \
  || bad "pyproject without ruff section" "$(cat "$R/new_mod.py")"

# --- 変異体: may_autofix always allows ---
# 同じ表をこの変異体に流し、少なくとも 1 件 red になることを実測する。
if [[ -z "${IN_MUTANT:-}" ]]; then
  MUT="$SB/mutant-hook.sh"
  python3 - "$HOOK" "$MUT" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = '  # shellcheck disable=SC2086\n  has_project_config "$file" $configs || return 1\n  head_version_clean "$file" "$mode" "$@"'
assert old in src, "mutation anchor not found"
open(sys.argv[2], "w").write(src.replace(old, '  return 0', 1))
PY
  if IN_MUTANT=1 HOOK="$MUT" bash "$0" >/dev/null 2>&1; then
    bad "mutant (may_autofix always allows) stays green" "the table above does not detect it"
  else
    ok "mutant (may_autofix always allows) goes red"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
