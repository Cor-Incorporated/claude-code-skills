#!/usr/bin/env bash
# vendor 成果物に対する検査集合の実行器 (aidd-governance#152)
#
# `.aidd-h5-vendor-lint` が宣言した検査を、宣言した成果物に対して実際に走らせる。
# **両リポジトリがこのファイルと宣言を vendor する。** スタンプ
# (scripts/h5-admission-check.source) が sha256 で固定するので、片方だけ検査を
# 足すと vendor parity が落ちる。
#
# ## なぜ要るか
#
# 単一正本 + vendoring (#137) を入れてから、正本の欠陥が 3 回とも
# **消費側の CI でしか**検出されなかった。正本側の CI は 3 回とも緑だった。
# 向きを反転しても再発したので、「どちらを正本にするか」ではなく
# **正本の検査集合が消費側の検査集合を包含していない**という構造の問題である。
#
# ## 緑にしない条件（fail-open を作らない）
#
#   宣言ファイルが無い          -> red。「検査が宣言されていない」を
#                                  「検査するものが無い」と読み替えない
#   artifact が 0 件            -> red。空宣言で緑にする逃げ道を塞ぐ
#   check が 0 件               -> red。同上
#   artifact のファイルが無い    -> red。宣言と実体の乖離
#   検査コマンドが存在しない      -> red（exit 127 を「合格」と読まない）
#
# **走らせた検査集合を必ず出力する**（#152 完了条件 3）。
# 「何を検査したか」が出力から読めなければ、両リポの一致を人が確認できない。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { printf 'H5-VENDOR-LINT-FAIL: cannot cd to repo root\n' >&2; exit 1; }

DECL="${H5_VENDOR_LINT_FILE:-$ROOT/.aidd-h5-vendor-lint}"

log() { printf '%s\n' "$*"; }
fail() { printf 'H5-VENDOR-LINT-FAIL: %s\n' "$*" >&2; }

if [[ ! -f "$DECL" ]]; then
  fail "宣言ファイルが無い: ${DECL}"
  fail "検査が宣言されていないことを「検査するものが無い」と読み替えない (aidd-governance#152)"
  exit 1
fi

artifacts=()
check_names=()
check_cmds=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%$'\r'}"
  case "$line" in
    ''|'#'*) continue ;;
  esac
  kw="${line%% *}"
  rest="${line#* }"
  case "$kw" in
    artifact)
      [[ -n "$rest" && "$rest" != "$line" ]] || { fail "artifact 行に値が無い: ${line}"; exit 1; }
      artifacts+=("$rest")
      ;;
    check)
      # check <name> <command with {}>
      name="${rest%% *}"
      cmd="${rest#* }"
      [[ -n "$name" && -n "$cmd" && "$cmd" != "$name" ]] || { fail "check 行の形式が違う: ${line}"; exit 1; }
      case "$cmd" in
        *'{}'*) ;;
        *) fail "check コマンドに {} が無い（対象ファイルが渡らない）: ${line}"; exit 1 ;;
      esac
      check_names+=("$name")
      check_cmds+=("$cmd")
      ;;
    *)
      fail "未知のキーワード: ${kw} (${line})"
      exit 1
      ;;
  esac
done < "$DECL"

if [[ "${#artifacts[@]}" -eq 0 ]]; then
  fail "artifact が 0 件。空の宣言で緑にはしない"
  exit 1
fi
if [[ "${#check_cmds[@]}" -eq 0 ]]; then
  fail "check が 0 件。空の宣言で緑にはしない"
  exit 1
fi

# #152 完了条件 3: 走らせた検査集合を出力から読めるようにする。
log "H5-VENDOR-LINT: declaration=${DECL#"$ROOT"/}"
log "H5-VENDOR-LINT: artifacts=${#artifacts[@]} checks=${#check_cmds[@]}"
for a in "${artifacts[@]}"; do log "H5-VENDOR-LINT:   artifact ${a}"; done
for i in "${!check_cmds[@]}"; do
  log "H5-VENDOR-LINT:   check ${check_names[$i]} = ${check_cmds[$i]}"
done

failures=0
missing=0
for a in "${artifacts[@]}"; do
  if [[ ! -f "$a" ]]; then
    fail "宣言された artifact が存在しない: ${a}"
    missing=$((missing + 1))
    continue
  fi
  for i in "${!check_cmds[@]}"; do
    cmd="${check_cmds[$i]//\{\}/$a}"
    # 語分割で実行する。宣言は自リポジトリが持つ信頼された行であり、
    # コマンドとフラグを空白区切りで書く前提（.aidd-h5-gates と同じ house idiom）。
    # shellcheck disable=SC2086
    out="$(eval "$cmd" 2>&1)"; rc=$?
    if [[ "$rc" -eq 127 ]]; then
      fail "検査コマンドが存在しない (exit 127): ${cmd}"
      fail "  実行できなかったことを「合格」と読まない"
      failures=$((failures + 1))
      continue
    fi
    if [[ "$rc" -ne 0 ]]; then
      fail "${check_names[$i]} が落ちた: ${a} (rc=${rc})"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      failures=$((failures + 1))
    else
      log "H5-VENDOR-LINT-PASS: ${check_names[$i]} ${a}"
    fi
  done
done

if [[ "$missing" -gt 0 || "$failures" -gt 0 ]]; then
  fail "missing=${missing} failed=${failures}"
  exit 1
fi

log "H5-VENDOR-LINT-PASS: ${#artifacts[@]} artifacts x ${#check_cmds[@]} checks, 0 failed"
