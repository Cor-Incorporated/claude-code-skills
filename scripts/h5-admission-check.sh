#!/usr/bin/env bash
# H5 — Admission fee for block-capable guards / completion verifiers (required check).
# Spec: aidd-governance design/harness-spec.md H5, design/ops/harness/h5-negative-test-gate.md
# H8 — requirement inventory field gate (T7-1 / Phase 20): delegation/handover
# docs in the diff must carry the 5 P3 fields plus the falsification/withdrawal
# declarations; empty or malformed → exit 1 + ledger inventory-field-empty.
# Spec: aidd-governance design/harness-spec.md H8
#
# Exit 0: not a guard PR, or 3-point set present
# Exit 1: guard PR missing negative-test evidence / ledger wiring / retirement condition
# Exit 0 with warn: fail-open structural smell (does not block)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_REF="${H5_BASE_REF:-origin/develop}"
HEAD_REF="${H5_HEAD_REF:-HEAD}"
PR_BODY="${H5_PR_BODY:-}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
LEDGER_PATH="${H5_LEDGER_PATH:-$HOME/.claude/hooks/ledger/guard-ledger.jsonl}"
LEDGER_SOURCE="${AIDD_LEDGER_SOURCE:-real}"

log() { printf '%s\n' "$*"; }
warn() { printf 'H5-WARN: %s\n' "$*" >&2; }
fail() { printf 'H5-FAIL: %s\n' "$*" >&2; }
append_h5_block() {
  local rule="$1" detail="$2" ts
  [[ -z "$LEDGER_PATH" ]] && return 0
  mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || true
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '{"ts":"%s","component":"H5","event":"block","rule":"%s","detail":"%s","source":"%s","agent":"ci"}\n' \
    "$ts" "$rule" "$detail" "$LEDGER_SOURCE" >>"$LEDGER_PATH" 2>/dev/null || true
}
# block ではない観測点。ブロックしていないので event は "measure"（H16 が既に
# 使っている語彙。台帳の event で分岐する consumer は無い）。
append_h5_measure() {
  local rule="$1" detail="$2" ts
  [[ -z "$LEDGER_PATH" ]] && return 0
  mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || true
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '{"ts":"%s","component":"H5","event":"measure","rule":"%s","detail":"%s","source":"%s","agent":"ci"}\n' \
    "$ts" "$rule" "$detail" "$LEDGER_SOURCE" >>"$LEDGER_PATH" 2>/dev/null || true
}

# ============ ゲート宣言マニフェスト (.aidd-h5-gates / aidd-governance#137) ============
# 本体は全リポで同一 (単一正本 + vendoring)。したがって本体には全ゲートのコードが
# 入っている。**どれを有効にするかはリポジトリごとに違う**ので、その差分を
# .aidd-h5-gates が宣言する。
#
# 起点: gov の本体を claude-code-skills へ置くと、ACL ゲートは
# design/ops/protected-identity-paths.txt が無いため恒久的に不活性のまま exit 0 に
# なる（実測 2026-09-02）。ログは出るが、「効いている」と「当たる対象が無い」が
# 出力上しか区別されず、機械判定が無かった。
#
# 書式は純 bash で読む。h5-admission.yml は actions/checkout だけを走らせ
# PyYAML も jq も入れない**うえに、そのファイルは両リポでバイト一致のため
# 触れない**。したがって YAML/JSON は使えない（house idiom の行ベースに合わせる）。
#
# on  かつ requires のファイルが無い → red。有効と宣言したのに当たる対象が無い、を通さない。
# off → ゲートを呼ばない。skip したことを毎回出力する（黙って緑にしない）。
# マニフェスト自体が無い → 従来どおり各ゲートの自己検出に委ねる（後方互換）。
#   ただし「マニフェストが無い」ことを出力する。フリートには 6 版が居るため。
GATES_FILE="${H5_GATES_FILE:-$ROOT/.aidd-h5-gates}"
_H5_GATES_PRESENT=0
[[ -f "$GATES_FILE" ]] && _H5_GATES_PRESENT=1

# マニフェストから 1 ゲートの行を引く。無ければ空を返す。
h5_gate_line() {
  local name="$1"
  [[ "$_H5_GATES_PRESENT" -eq 1 ]] || return 0
  # 先頭が名前と一致する非コメント行だけ。名前は完全一致で引く。
  awk -v n="$name" '
    /^[[:space:]]*(#|$)/ { next }
    { if ($1 == n) { print; exit } }
  ' "$GATES_FILE"
}

# ゲートを走らせてよいか。0=走らせる / 1=走らせない。
# requires の欠落は「走らせない」ではなく **red**（呼び出し側が exit 1 する）。
_H5_GATE_SKIP_REASON=""
h5_gate_enabled() {
  local name="$1" line tok state req missing=() p
  _H5_GATE_SKIP_REASON=""
  line="$(h5_gate_line "$name")"

  if [[ -z "$line" ]]; then
    if [[ "$_H5_GATES_PRESENT" -eq 1 ]]; then
      # マニフェストはあるのに、この装置の欄が無い。宣言漏れなので走らせない
      # ことにはせず、走らせたうえで宣言漏れを出す（判定は緩めない）。
      warn "H5-GATES: $name が $GATES_FILE に宣言されていない — 従来の自己検出で走らせる"
    fi
    return 0
  fi

  state="$(printf '%s\n' "$line" | awk '{print $2}')"
  if [[ "$state" == "off" ]]; then
    _H5_GATE_SKIP_REASON="$(printf '%s\n' "$line" | sed -n 's/.*reason=//p')"
    return 1
  fi

  # on。requires が全部実在するかを確かめる。
  req="$(printf '%s\n' "$line" | sed -n 's/.*requires=\([^ ]*\).*/\1/p')"
  if [[ -n "$req" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ -e "$ROOT/$p" ]] || missing+=("$p")
    done <<<"$(printf '%s\n' "$req" | tr ',' '\n')"
    if [[ ${#missing[@]} -gt 0 ]]; then
      fail "H5-GATES: ゲート '$name' は on と宣言されているが、必要な宣言ファイルが無い"
      printf '  missing: %s\n' "${missing[@]}" >&2
      fail "宣言ファイルを持たないゲートを『有効』と数えない (aidd-governance#137)"
      fail "対処: そのファイルを追加するか、$GATES_FILE で '$name off reason=...' と宣言する"
      append_h5_block "gate-declared-without-declaration-file" "gate=$name missing=${missing[*]}"
      return 2
    fi
  fi
  return 0
}

# ゲート 1 本を宣言に従って実行する。宣言漏れ・requires 欠落は exit 1 させる。
h5_run_gate() {
  local name="$1" fn="$2" rc
  h5_gate_enabled "$name"; rc=$?
  case "$rc" in
    1) log "H5-GATES-SKIP: $name は off と宣言されている${_H5_GATE_SKIP_REASON:+（${_H5_GATE_SKIP_REASON}）}" ; return 0 ;;
    2) return 1 ;;
  esac
  "$fn"
}

# --- Collect PR body (CI or local override) ---
if [[ -z "$PR_BODY" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  PR_BODY="$(python3 - <<'PY' 2>/dev/null || true
import json, os
path = os.environ["GITHUB_EVENT_PATH"]
with open(path) as f:
    ev = json.load(f)
body = (ev.get("pull_request") or {}).get("body") or ""
print(body)
PY
)"
fi
if [[ -z "$PR_BODY" && -n "${H5_PR_NUMBER:-}" ]]; then
  PR_BODY="$(gh pr view "$H5_PR_NUMBER" --json body -q .body 2>/dev/null || true)"
fi

# --- Diff paths ---
if [[ -n "${H5_DIFF_FILES:-}" ]]; then
  # newline or space separated override (tests)
  DIFF_FILES="$(printf '%s\n' $H5_DIFF_FILES)"
else
  # `--depth=1` truncates the local repository, not just this fetch: it writes
  # .git/shallow and every later merge-base against the base ref fails. CI starts
  # from a shallow checkout so the flag costs nothing there, but running this gate
  # locally against a full clone destroys history. Measured 2026-08-27 in Grift:
  # doing so made PR #2140 report "refusing to merge unrelated histories".
  # Ported from Cor-Incorporated/Grift eb6df7415 (PR #2152). Ref: aidd-governance#89
  h5_base_branch="$(echo "$BASE_REF" | sed 's#^origin/##')"
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    git fetch --no-tags --depth=1 origin "$h5_base_branch" 2>/dev/null || true
  else
    git fetch --no-tags origin "$h5_base_branch" 2>/dev/null || true
  fi
  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    DIFF_FILES="$(git diff --name-only "$BASE_REF"...$HEAD_REF 2>/dev/null || git diff --name-only "$BASE_REF" $HEAD_REF 2>/dev/null || true)"
  else
    DIFF_FILES="$(git diff --name-only HEAD~1...HEAD 2>/dev/null || true)"
  fi
fi

is_guard_pr=0
# Structural triggers: any path that can change guard force projection.
# Keep this set and the H5-guard:no exemption-denylist (below) IDENTICAL — both
# go through h5_is_structural_path(), so they cannot drift apart.
#
# **極性は「除外を列挙する」側である。** 以前は逆で、カバーする拡張子を
# `hooks/.+\.sh|scripts/.+\.sh` と列挙していた。その形は**新しい拡張子を黙って
# 免除する。** 実測 (2026-09-02, aidd-governance#137):
#   hooks/pre-commit                   → 免除（aidd-governance に実在する git hook）
#   hooks/pre-push                     → 免除（同上）
#   hooks/lib/h1-iteration-class.py    → 免除
#   scripts/workflow-permission-scan.py → 免除
#   scripts/lib/gh-permission-map.yaml → 免除
# いずれも block 権限または完了判定に関与するのに guard fee の外に出ていた。
# `.ts` の hook helper を足せば、やはり誰も気づかないまま外に出る。
#
# したがって hooks/ と scripts/ の配下は**既定で構造パス**とし、文書だけを
# 明示的に除外する。ERE に否定先読みは無いので、単一 regex へ押し込まず
# 「前方一致 → 除外条件」の 2 段で引く。そのほうが読んで検証できる。
#
# 除外してよいのは在庫で確認した文書系だけである（`.md`）。**`.py` `.yaml`
# 拡張子なしは除外しない。** 除外を増やすときは、そのファイルが block 権限にも
# 完了判定にも関与しないことを在庫で示すこと。
_H5_STRUCT_RE='^(hooks/|scripts/|settings\.json|\.github/workflows/)'
# 文書のみの除外。ここを空にすると scripts/README.md が block へ戻る（片側変異）。
_H5_STRUCT_DOC_RE='\.md$'

# 1 パスが構造パスかを判定する。前方一致してから文書除外を引く 2 段。
h5_is_structural_path() {
  local p="$1"
  printf '%s' "$p" | grep -qE "$_H5_STRUCT_RE" || return 1
  printf '%s' "$p" | grep -qiE "$_H5_STRUCT_DOC_RE" && return 1
  return 0
}

# DIFF_FILES に構造パスが 1 本でもあるか。
h5_diff_has_structural_path() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    h5_is_structural_path "$f" && return 0
  done <<<"$(printf '%s\n' "$DIFF_FILES")"
  return 1
}

if h5_diff_has_structural_path; then
  is_guard_pr=1
fi
# Self-declaration (PR template)
if printf '%s' "$PR_BODY" | grep -qiE 'H5-guard:\s*yes|ブロック権限|完了判定検証器|block-capable guard'; then
  is_guard_pr=1
fi
# H5-guard: no may only clear the flag when NO structural path is touched.
# Previously the denylist was a subset (hooks/*.sh|hooks/lib|settings) so
# scripts/** and .github/workflows/** could self-exempt — that hole is closed.
if printf '%s' "$PR_BODY" | grep -qiE 'H5-guard:\s*no' \
  && ! printf '%s' "$PR_BODY" | grep -qiE 'H5-guard:\s*yes'; then
  if ! h5_diff_has_structural_path; then
    is_guard_pr=0
  fi
fi

# H5-E2E applies to the existing structural scope by default. Repositories may
# opt additional, repo-relative paths into the form gate through one glob per
# line in .aidd-e2e-paths. This does not turn application code into a guard PR:
# the existing three-point guard fee remains scoped by is_guard_pr.
is_e2e_pr="$is_guard_pr"
E2E_PATHS_FILE="$ROOT/.aidd-e2e-paths"
if [[ -f "$E2E_PATHS_FILE" ]]; then
  while IFS= read -r raw_pattern || [[ -n "$raw_pattern" ]]; do
    pattern="${raw_pattern%$'\r'}"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    while IFS= read -r changed_path; do
      [[ -z "$changed_path" ]] && continue
      # shellcheck disable=SC2053 # RHS is intentionally a repository-declared glob.
      if [[ "$changed_path" == $pattern ]]; then
        is_e2e_pr=1
        break 2
      fi
    done <<<"$DIFF_FILES"
  done <"$E2E_PATHS_FILE"
fi
if printf '%s\n' "$DIFF_FILES" | grep -qxF '.aidd-e2e-paths'; then
  is_e2e_pr=1
fi

# ============ H8: requirement inventory field check (T7-1) ============
# Spec: aidd-governance design/harness-spec.md H8
# P3 装置欄: (1) 一次資料パス (2) 要求インベントリ (3) 突合表 (4) 標準質問 5 問 (5) 北極星
# Phase 20 補助欄: (6) 反証軸 (7) 撤収。委任契約の既存 10 欄とは別枠。
# Delegation/handover docs in the diff are inspected; a doc counts as a
# delegation contract only when it carries 委任契約/要求インベントリ marker
# (avoids false hits on ordinary prose). Empty section = red + ledger row.
_H8_DOC_RE='^(docs/handover/|delegation/|.*delegation.*\.md$|.*handover.*\.md$)'
_H8_FIELDS=(
  "一次資料|references|一次資料パス"
  "要求インベントリ|要件インベントリ"
  "突合表|受入基準"
  "標準質問|ユーザー像|審美|LLM 挙動境界|安全境界|セキュリティ境界"
  "北極星|メトリクス|測定周期"
  "反証軸"
  "撤収"
  "識別子境界|触ってよい識別子|触ってはいけない識別子"
)
_H8_FIELD_NAMES=(
  "一次資料"
  "要求インベントリ"
  "突合表"
  "標準質問"
  "北極星"
  "反証軸"
  "撤収"
  "識別子境界"
)
# 本欄より後に追加された欄は、既存文書に対して免除する（下記 H8-EXEMPT）。
# ここに欄名を書くことが免除の宣言であり、免除件数が 0 になったら
# この配列と免除ロジックごと削除する（撤収条件。日付では判定しない）。
_H8_FIELDS_SINCE_93=("識別子境界")

# 識別子境界欄はリポジトリ任意ゲート (#93 ④)。off を宣言したリポでは欄を要求しない。
# 本体は全リポ共通なので、外すのは配列からであってコードからではない。
# `if ! cmd; then` の中で $? を読むと `!` の結果 (0) になるため、戻り値は明示的に捕る。
set +e
h5_gate_enabled h8-identifier-scope
_h8_id_rc=$?
set -e
if [[ "$_h8_id_rc" -eq 2 ]]; then
  exit 1
elif [[ "$_h8_id_rc" -eq 1 ]]; then
  log "H5-GATES-SKIP: h8-identifier-scope は off と宣言されている${_H5_GATE_SKIP_REASON:+（${_H5_GATE_SKIP_REASON}）}"
  _H8_FIELDS=("${_H8_FIELDS[@]:0:7}")
  _H8_FIELD_NAMES=("${_H8_FIELD_NAMES[@]:0:7}")
  # Bash 3.2 では set -u 下の空配列展開が unbound variable になる。空文字 1 要素を
  # 置くのではなく、参照側 (h8_is_new_field) を `${arr[@]-}` で守る。
  _H8_FIELDS_SINCE_93=()
fi

# 候補語に**裸の「識別子」を入れない。** 入れると `## 識別子の命名規則` のような
# 無関係な見出しに一致し、`**/*acl*` が oracle に一致したのと同型になる
# （2026-09-02、同日 3 面で踏んだ表面形一致）。複合語に限定してある。
h8_docs=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if printf '%s' "$f" | grep -qE "$_H8_DOC_RE" && [[ -f "$f" ]]; then
    h8_docs+=("$f")
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES")"

# 既存文書は新欄を免除する。判定は「その文書が base ref に存在したか」だけで、
# 日付を見ない（CI が日付で挙動を変えると検証しづらい）。git が既に持っている
# 情報を読むだけなので、新しい状態を作らない。
#
# **免除は黙って通さない。** 免除したことと件数を毎回出力する。見えないと
# 半年後に「全文書が新欄を持っている」と誤認する。件数が 0 になったら
# 免除ロジックごと削除する（_H8_FIELDS_SINCE_93 の撤収条件）。
h8_is_preexisting() {
  git -C "$ROOT" cat-file -e "$BASE_REF:$1" 2>/dev/null
}
h8_is_new_field() {
  local name="$1" n
  # Bash 3.2: set -u 下で空配列を "${a[@]}" 展開すると unbound variable になる。
  # h8-identifier-scope を off にしたリポでは実際に空になるため必ず守る。
  [[ -z "${_H8_FIELDS_SINCE_93[*]-}" ]] && return 1
  for n in "${_H8_FIELDS_SINCE_93[@]}"; do
    [[ "$n" == "$name" ]] && return 0
  done
  return 1
}

h8_missing=()
h8_exempt_count=0
if [[ -n "${h8_docs[*]-}" ]]; then
  for f in "${h8_docs[@]}"; do
    grep -qE '委任契約|要求インベントリ' "$f" || continue
    h8_doc_preexisting=0
    h8_is_preexisting "$f" && h8_doc_preexisting=1
    for ((h8_i = 0; h8_i < ${#_H8_FIELDS[@]}; h8_i++)); do
      field="${_H8_FIELDS[$h8_i]}"
      field_name="${_H8_FIELD_NAMES[$h8_i]}"
      if [[ "$h8_doc_preexisting" -eq 1 ]] && h8_is_new_field "$field_name"; then
        log "H8-EXEMPT: $f は base ref に存在するため新欄 $field_name を要求しない（既存文書）"
        h8_exempt_count=$((h8_exempt_count + 1))
        continue
      fi
      if ! python3 - "$f" "$field" "$field_name" <<'PY'
import re, sys
doc, pat, field_name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(doc, encoding="utf-8").read()
m = re.search(rf'(?im)^#{{1,4}}\s*(?:{pat})[^\n]*\n([\s\S]*?)(?=^#{{1,4}}\s|\Z)', text)
if not m:
    sys.exit(1)
content = m.group(1).strip()
if len(content) < 20 or re.fullmatch(r'[-*\s\[\]xX]*', content):
    sys.exit(1)
if field_name == "反証軸":
    valid = (
        re.search(r"F1", content, re.I)
        and re.search(r"軸|真理値|×", content, re.I)
    ) or (
        re.search(r"F2", content, re.I)
        and re.search(r"事故入力|再現入力|既知入力", content, re.I)
    ) or (
        re.search(r"F3", content, re.I)
        and re.search(r"片側|変異|mutation", content, re.I)
    )
    if not valid:
        sys.exit(1)
if field_name == "識別子境界":
    # 触ってよい / 触ってはいけない の区別が書かれているか、
    # 該当しない理由が書かれているか。どちらも無ければ欄として成立しない。
    if not re.search(r"触ってよい|触ってはいけない|該当なし", content):
        sys.exit(1)
if field_name == "撤収" and not re.search(
    r"(?<![A-Za-z0-9_-])(active|recover|preserve|retire)(?![A-Za-z0-9_-])",
    content,
    re.I,
):
    sys.exit(1)
sys.exit(0)
PY
      then
        h8_missing+=("$f: $field_name")
      fi
    done
  done
fi

if [[ -n "${h8_missing[*]-}" ]]; then
  fail "H8: requirement inventory incomplete (inventory-field-empty)"
  printf '  %s\n' "${h8_missing[@]}" >&2
  if [[ -n "$LEDGER_PATH" ]]; then
    mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || true
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    for m in "${h8_missing[@]}"; do
      doc="${m%%:*}"
      miss="${m#*: }"
      printf '{"ts":"%s","component":"H8","event":"warn","rule":"inventory-field-empty","subject":{"doc":"%s","missing":["%s"]},"source":"%s","agent":"ci"}\n' \
        "$ts" "$doc" "$miss" "$LEDGER_SOURCE" >>"$LEDGER_PATH" 2>/dev/null || true
    done
  fi
  exit 1
fi
if [[ -n "${h8_docs[*]-}" ]]; then
  log "H8-PASS: inventory fields present in ${#h8_docs[@]} delegation doc(s)"
  # 免除件数を毎回出す。減っていく（既存文書が更新されて新欄を持つ）のを
  # 追えるようにするため。減らないなら移行が進んでいない。
  log "H8-EXEMPT-COUNT: ${h8_exempt_count}（0 になったら免除ロジックを削除する）"
  if [[ "$h8_exempt_count" -gt 0 && -n "$LEDGER_PATH" ]]; then
    mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || true
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '{"ts":"%s","component":"H8","event":"warn","rule":"inventory-field-exempt","subject":{"exempt":%s,"docs":%s},"source":"%s","agent":"ci"}\n' \
      "$ts" "$h8_exempt_count" "${#h8_docs[@]}" "$LEDGER_SOURCE" >>"$LEDGER_PATH" 2>/dev/null || true
  fi
fi

# ====== 同族修理カウンタ N=3 ゲート (aidd-governance#88 + #85) ======
# 起点事故: Grift v2-alpha-cd bootstrap 境界へ 16 本の "exact" 修理 PR が連続し、
# うち 13 本は「Turn 4 で Terraform 定常化」という自らの戦略宣言の後だった。
# 再裁定は 0 回。#1985 の Do-Not-Resume 裁定は失効条件を持たないまま無期限化した。
#
# family は PR 本文の申告ではなく **変更パスから導出** する。申告に依らないので
# 「今回が 1 回目」と書くだけの自己免除ができない。
# 対象は fix 型 PR に限る（feat/docs/chore は数えない = 誤検知の抑制）。
# ============ #93 ①: access-control surface change gate ============
# 起点 (2026-08-27): 承認語 `cloudia-handoff` に対し `grep -ril cloudia` で
# 18 ファイルを列挙し、そのうち 2 件が Tailscale ACL の実アカウント行だった。
# 削除していれば人が tailnet へ入れなくなっていた。検出は人が 1 件ずつ読む
# 手作業のみで、機械的な検出は 0 だった。
#
# #93 の項目② は「アクセス制御ファイルを削除禁止リストに置き、**変更には
# 個別承認を要求する**」。前半（宣言と報告）は #118 で入ったが、後半の強制点が
# 無かった。本ゲートがそれである。
#
# 判定は「誰が変更したか」ではなく「**明示の承認が本文にあるか**」で引く
# （aidd-governance#100）。AI でも人でも、マーカーがあれば通り、無ければ止まる。
#
# **保護パスが 1 件も無いリポジトリでは、それを出力に出す。** 黙って緑にすると
# 「ゲートが効いている」と「ゲートが当たる対象を持っていない」が区別できず、
# 本日 5 回踏んだ形（配備した／登録した／検査したつもり）を繰り返す。
h5_acl_change_gate() {
  local decl="$ROOT/design/ops/protected-identity-paths.txt"
  if [[ ! -f "$decl" ]]; then
    log "H5-ACL: 保護パス宣言が無い（${decl}）— 本ゲートは判定していない"
    return 0
  fi

  local globs=()
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    globs+=("$line")
  done <"$decl"
  [[ ${#globs[@]} -eq 0 ]] && { log "H5-ACL: 宣言が空 — 判定していない"; return 0; }

  local touched=() f g
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2053 # RHS is intentionally a declared glob
      if [[ "$f" == $g ]]; then touched+=("$f"); break; fi
      if [[ "$g" == '**/'* ]]; then
        # shellcheck disable=SC2053
        if [[ "$f" == ${g#'**/'} ]]; then touched+=("$f"); break; fi
      fi
    done
  done <<<"$(printf '%s\n' "$DIFF_FILES")"

  # このリポジトリに保護パスが実在するかも数える。0 なら本ゲートは
  # 「当たる対象を持っていない」のであって「守っている」のではない。
  local present=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$f" == $g ]]; then present=$((present + 1)); break; fi
      if [[ "$g" == '**/'* ]]; then
        # shellcheck disable=SC2053
        if [[ "$f" == ${g#'**/'} ]]; then present=$((present + 1)); break; fi
      fi
    done
  done <<<"$(git -C "$ROOT" ls-files 2>/dev/null || true)"

  if [[ ${#touched[@]} -eq 0 ]]; then
    log "H5-ACL-PASS: この diff にアクセス制御面は無い（宣言 ${#globs[@]} glob / リポ内実在 $present 件）"
    return 0
  fi

  if printf '%s' "$PR_BODY_EVIDENCE" | grep -qE '(^|[[:space:]])ACL-CHANGE:[[:space:]]*\S.{19,}'; then
    log "H5-ACL-PASS: アクセス制御面 ${#touched[@]} 件の変更に ACL-CHANGE の明示承認がある"
    printf '  %s\n' "${touched[@]}"
    return 0
  fi

  fail "H5-ACL: この PR はアクセス制御面を変更しているが ACL-CHANGE の明示承認が無い"
  printf '  %s\n' "${touched[@]}" >&2
  fail "アクセス制御の削除は非対称である。機能の残骸は後で消せるが、"
  fail "アクセス権を消すと人が締め出され、しかも本人しか復旧できない。"
  fail "Required: ACL-CHANGE: <20 文字以上の理由。誰のどのアクセスをどう変えるか>"
  append_h5_block "acl-change-unacknowledged" "touched=${#touched[@]}"
  return 1
}

h5_repair_family_gate() {
  local breaker="$ROOT/scripts/repair-loop-breaker.sh"
  [[ -x "$breaker" || -f "$breaker" ]] || return 0

  # fix 型の PR か（base..head の commit subject で判定）
  local subjects
  subjects="$(git log --format='%s' "$BASE_REF..$HEAD_REF" 2>/dev/null || true)"
  printf '%s\n' "$subjects" | grep -qiE '^(fix|hotfix)(\(|:)' || return 0

  local family paths
  paths="$(printf '%s\n' "$DIFF_FILES" | grep -v '^$' || true)"
  [[ -z "$paths" ]] && return 0
  family="$(printf '%s\n' "$paths" | bash "$breaker" family --paths-from - 2>/dev/null || true)"
  [[ -z "$family" ]] && return 0

  local ledger_file count
  ledger_file="$(mktemp)"
  bash "$breaker" derive --base "$BASE_REF" --head "$HEAD_REF" \
    --window-days "${H5_REPAIR_WINDOW_DAYS:-90}" >"$ledger_file" 2>/dev/null || true
  # `grep -c` は不一致のとき stdout へ "0" を出した**うえで** exit 1 を返す。
  # したがって `$(grep -c ... || echo 0)` は "0\n0" になり、直後の
  # `[[ "$count" -lt "$threshold" ]]` が算術構文エラーで false になって
  # else へ落ちる。= 前例ゼロの fix PR が全部ブロックされる。
  # h5-admission はこのリポジトリ唯一の required check なので、この誤検知は
  # 全 fix PR を止める。2026-09-02 実測: prior=0 の合成 PR が exit 1。
  # awk は不一致でも exit 0 で 1 行だけ出すため、フォールバックが不要になる。
  count="$(awk '/"kind":"repair-pr"/ {n++} END {print n+0}' "$ledger_file" 2>/dev/null)"
  # 算術比較へ渡る前に単一トークンであることを確かめる（改行が混ざれば非一致）。
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  local threshold="${H5_REPAIR_THRESHOLD:-3}"

  if [[ "$count" -lt "$threshold" ]]; then
    log "H5-REPAIR-PASS: family=$family prior fix merges=$count < threshold=$threshold"
    rm -f "$ledger_file"
    return 0
  fi

  local entry
  entry="$(printf '%s' "$PR_BODY" | grep -oiE 'H5-READJUDICATION:[[:space:]]*\S+' | head -1 \
    | sed -E 's/^[Hh]5-[Rr][Ee][Aa][Dd][Jj][Uu][Dd][Ii][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//')"
  if [[ -z "$entry" ]]; then
    fail "H5-REPAIR: family=$family has $count prior fix merges (>= $threshold) and no readjudication"
    fail "Required: H5-READJUDICATION: <path to a design/ops/readjudication/*.md entry>"
    fail "Template: design/ops/readjudication/TEMPLATE.md"
    fail "Prior repairs in window:"
    sed -e 's/^/    /' "$ledger_file" >&2
    append_h5_block "repair-family-threshold" "family=$family count=$count"
    rm -f "$ledger_file"
    return 1
  fi
  if ! bash "$breaker" validate-entry --entry "$ROOT/$entry" --family "$family" >&2 \
    && ! bash "$breaker" validate-entry --entry "$entry" --family "$family" >&2; then
    fail "H5-REPAIR: readjudication entry invalid or missing: $entry"
    append_h5_block "repair-family-entry-invalid" "family=$family entry=$entry"
    rm -f "$ledger_file"
    return 1
  fi
  log "H5-REPAIR-PASS: family=$family count=$count released by $entry"
  rm -f "$ledger_file"
  return 0
}

if ! h5_run_gate repair-family h5_repair_family_gate; then
  exit 1
fi


# Ignore negation/meta lines so "missing 陰性テスト" does not count as evidence.
# H5-E2E remains a form declaration only: this script cannot prove that the
# command or output is truthful (T8-4).
#
# 危険: このフィルタは **行単位** で落とす。issue #134 まで、マーカー行に
# メタ語が 1 語でも混ざるとマーカーごと証拠から消えていた。
#   H5-NEGATIVE: 修正前は「未記入」の分岐が red になることを実測（rc=1）
#   H5-NEGATIVE: expect red だった 3 件を修正後 green に反転させた
# どちらも本物の陰性テスト証跡だが `未記入` / `expect red` を含むため行ごと
# 消え、negative-test-evidence 欠落で exit 1 になっていた。**ゲートが要求して
# いる内容を最も自然な語で書くと落ちる。** 表面形一致は引用・否定・言及を
# 区別できない、の evidence 側の実例。
#
# 直し方は「構造で分ける」。内容の真偽は判定しない（C15 の線は越えない）:
#   - マーカー行（H5-*: / ACL-CHANGE:）は残し、メタ語だけを空白 1 個に潰す
#   - 潰した結果、値が空になったマーカー行は **行ごと落とす**（= 値がメタ語
#     だけだった行。修正前と同じ結末になる。理由は下の「空マーカーを残すな」）
#   - マーカーを持たない散文行は従来どおり行ごと落とす（元の穴を開けない）
#
# マーカー値が実質を持つかは **各消費側の既存の長さ判定** が決める
# （has_marker の `.{8,}` / ACL の `.{19,}` / H5-E2E-OUT の 20 文字）。
# ここで新しい閾値を書くと同じ事実が 2 箇所になり、片方だけ動く。書かないこと。
# 置換後 `H5-NEGATIVE: 未記入` は `H5-NEGATIVE:  ` になり `\S` を失って落ちる。
#
# 置換先が「削除」ではなく「空白 1 個」なのは意図的。削除するとトークンが
# 接合して判定が緩む経路ができる（`H5-E2E: nexpect redone` -> `none`、
# `H5-SUBTRACTION: Nexpect red/A` -> `N/A`）。空白なら接合しない。
#
# _H5_META_RE は 2 段で共有する。片方だけ語を足すと、マーカー行では潰される
# のに散文行では残る（またはその逆）ので、必ずこの 1 箇所だけを編集すること。
# 語を足すときは `/` を含めないこと（下の sed の s/// 区切り文字と衝突する）。
_H5_META_RE='intentionally missing|expect red|do not merge|falsification only|未記入|TODO 陰性|TODO 台帳|TODO 廃止'
# 消費側が PR_BODY_EVIDENCE から読むマーカーの閉語彙。行番号でなく名前で書く
# （この節自体が行をずらすため）: h5_acl_change_gate の ACL-CHANGE、e2e_reason
# ブロックの H5-E2E / H5-E2E-OUT、has_marker の H5-NEGATIVE / LEDGER / RETIRE、
# subtraction ゲートの H5-SUBTRACTION。
# has_marker は grep -i なので、ここの address にも I を付ける。片側だけ
# case-sensitive だと `Expect Red` と書くだけでゲートを迂回できる。
_H5_MARKER_RE='^[[:space:]]*(H5-[A-Za-z0-9_-]+|ACL-CHANGE)[[:space:]]*:'
# 空マーカーを残すな。値が空になったマーカー行を本文に残すと、e2e_reason
# ブロックの `^\s*H5-E2E-OUT:\s*(.*?)\s*$` の `\s*` が **改行を跨いで** 次の行を値として
# 掴む（実測 2026-09-03: `H5-E2E-OUT: expect red` が潰されて空になり、次行の
# `H5-NEGATIVE: ...` 54 文字が E2E 出力として採用されて exit 0 になった）。
# 潰して空になった行は「値がメタ語だけだった」行なので、修正前と同じく落とす。
# 内側を /META/I で括ってあるので、**もともと空だったマーカー行には触らない**
# （それは #134 の対象外であり、ここで挙動を変えると別ゲートの要求が動く）。
_H5_NEUTRALIZE_MARKERS=("-E" "/${_H5_MARKER_RE}/I{
  /${_H5_META_RE}/I{
    s/(${_H5_META_RE})/ /gI
    /${_H5_MARKER_RE}[[:space:]]*\$/Id
  }
}")

PR_BODY_EVIDENCE="$(printf '%s\n' "$PR_BODY" \
  | sed "${_H5_NEUTRALIZE_MARKERS[@]}" \
  | grep -viE "$_H5_META_RE" || true)"

# 落としたこと・潰したことを観測可能にする。ここが無いと「正当な証跡を持ち
# ながら落とされた PR」は無音で消え、件数を数える手段が無い（#134 の北極星）。
# `grep -c` は不一致時に stdout へ "0" を出した**うえで** exit 1 を返すので
# `|| echo 0` は "0\n0" になる。`|| true` を使うこと（同じ罠を h5_repair_family_gate
# が踏んでいて、そこに再発防止のコメントがある）。
# マーカーの照合は実際のフィルタと同じく大文字小文字を無視する（-i）。ここだけ
# case-sensitive にすると、数え上げと実際のフィルタが食い違う。
_h5_marker_meta="$(printf '%s\n' "$PR_BODY" | grep -iE "$_H5_MARKER_RE" | grep -ciE "$_H5_META_RE" || true)"
_h5_rescued="$(printf '%s\n' "$PR_BODY" | grep -iE "$_H5_MARKER_RE" | grep -iE "$_H5_META_RE" \
  | sed "${_H5_NEUTRALIZE_MARKERS[@]}" | grep -c '' || true)"
_h5_marker_dropped=$(( ${_h5_marker_meta:-0} - ${_h5_rescued:-0} ))
_h5_prose_dropped="$(printf '%s\n' "$PR_BODY" | sed "${_H5_NEUTRALIZE_MARKERS[@]}" | grep -ciE "$_H5_META_RE" || true)"
if [[ "${_h5_marker_meta:-0}" -gt 0 || "${_h5_prose_dropped:-0}" -gt 0 ]]; then
  log "H5-EVIDENCE: meta filter — rescued=${_h5_rescued} marker-dropped=${_h5_marker_dropped} prose-dropped=${_h5_prose_dropped}"
  printf '%s\n' "$PR_BODY" | grep -iE "$_H5_MARKER_RE" | grep -iE "$_H5_META_RE" \
    | sed "${_H5_NEUTRALIZE_MARKERS[@]}" | sed -e 's/^/  kept(neutralized): /' || true
  printf '%s\n' "$PR_BODY" | sed "${_H5_NEUTRALIZE_MARKERS[@]}" | grep -iE "$_H5_META_RE" \
    | sed -e 's/^/  dropped(prose): /' || true
  # rescued>0 = 旧フィルタなら証跡が消えていた PR。この 1 行が北極星の分子で、
  # 「正当な証跡を持ちながら h5 に落とされた PR」を初めて数えられるようにする。
  append_h5_measure "evidence-filter" \
    "rescued=${_h5_rescued} marker-dropped=${_h5_marker_dropped} prose-dropped=${_h5_prose_dropped}"
fi

# ACL ゲートは PR_BODY_EVIDENCE に依存する（否定・メタ行を除いた本文で
# マーカーを探すため）。定義より前に呼ぶと set -u で落ちる。
if ! h5_run_gate acl-change h5_acl_change_gate; then
  exit 1
fi

if [[ "$is_e2e_pr" -eq 1 ]]; then
  set +e
  e2e_reason="$(H5_E2E_BODY="$PR_BODY_EVIDENCE" python3 - <<'PY'
import os
import re

body = os.environ.get("H5_E2E_BODY", "")
markers = re.findall(r"(?im)^\s*H5-E2E:\s*(.*?)\s*$", body)
if not markers:
    print("e2e-marker-missing")
    raise SystemExit(1)

value = markers[0].strip()
if value.casefold() == "none":
    raise SystemExit(0)
if not value:
    print("e2e-command-empty")
    raise SystemExit(1)

outputs = re.findall(r"(?im)^\s*H5-E2E-OUT:\s*(.*?)\s*$", body)
if not outputs:
    print("e2e-output-missing")
    raise SystemExit(1)
if len(outputs[0].strip()) < 20:
    print("e2e-output-too-short")
    raise SystemExit(1)
PY
)"
  e2e_rc=$?
  set -e
  if [[ "$e2e_rc" -ne 0 ]]; then
    fail "H5-E2E declaration incomplete: $e2e_reason"
    fail "Required: H5-E2E: none OR H5-E2E: <command> + H5-E2E-OUT: <20+ chars output/log path>"
    append_h5_block "e2e-declaration-incomplete" "$e2e_reason"
    exit 1
  fi
  log "H5-E2E-PASS: execution-boundary declaration present"
fi

if [[ "$is_guard_pr" -eq 0 ]]; then
  if [[ "$is_e2e_pr" -eq 1 ]]; then
    log "H5-PASS: repository-declared E2E path (guard three-point fee not applicable)"
  else
    log "H5-PASS: not a guard/verifier PR (no structural trigger / declared N/A)"
  fi
  exit 0
fi

log "H5: guard/verifier PR detected — checking 3-point admission fee"

missing=()

# Prefer explicit machine markers (H5-NEGATIVE: / H5-LEDGER: / H5-RETIRE:)
# Fall back to Japanese/English section content of sufficient length.
has_marker() {
  local key="$1"
  printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE "(^|[[:space:]])H5-${key}:[[:space:]]*\\S.{8,}"
}

has_section_content() {
  local title_re="$1"
  H5_SECTION_BODY="$PR_BODY_EVIDENCE" python3 -c "
import re, os, sys
title = sys.argv[1]
body = os.environ.get('H5_SECTION_BODY', '')
pat = re.compile(rf'(?im)^#{{1,3}}\\s*(?:{title})\\s*\$([\\s\\S]*?)(?=^#{{1,3}}\\s|\\Z)')
m = pat.search(body)
if not m:
    sys.exit(1)
content = m.group(1).strip()
if len(content) < 20:
    sys.exit(1)
if re.fullmatch(r'[-*\\[\\] xX\\s]*', content):
    sys.exit(1)
sys.exit(0)
" "$title_re" 2>/dev/null
}

# (1) Negative test evidence (known-bad → red measured)
neg_ok=0
has_marker "NEGATIVE" && neg_ok=1
has_section_content '陰性テスト|negative[[:space:]-]?test' && neg_ok=1
if [[ "$neg_ok" -eq 0 ]]; then
  if printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE '(陰性テスト|negative[[:space:]-]?test)' \
    && printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE '(red 実測|exit[[:space:]]*[12]|FAILED|known-bad|inject)'; then
    neg_ok=1
  fi
fi
[[ "$neg_ok" -eq 0 ]] && missing+=("negative-test-evidence")

# (2) H6 ledger wiring — body marker/section or changed hook sources
has_ledger_body=0
has_marker "LEDGER" && has_ledger_body=1
has_section_content '台帳|ledger|防御台帳' && has_ledger_body=1
printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE 'aidd_ledger_append|guard-ledger\.jsonl' && has_ledger_body=1
has_ledger_code=0
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  if grep -qE 'aidd_ledger_append|guard-ledger\.jsonl|aidd-ledger' "$f" 2>/dev/null; then
    has_ledger_code=1
    break
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES" | grep -E '^hooks/|^scripts/h5' || true)"
if [[ "$has_ledger_body" -eq 0 && "$has_ledger_code" -eq 0 ]]; then
  if printf '%s\n' "$DIFF_FILES" | grep -q 'h5-admission' && printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE '台帳|ledger'; then
    has_ledger_body=1
  fi
fi
if [[ "$has_ledger_body" -eq 0 && "$has_ledger_code" -eq 0 ]]; then
  missing+=("ledger-wiring")
fi

# (3) Retirement condition declared
ret_ok=0
has_marker "RETIRE" && ret_ok=1
has_section_content '廃止条件|retirement' && ret_ok=1
if printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE '(廃止条件|retirement).{0,80}(90|発火ゼロ|FP|false.?positive|退役)'; then
  ret_ok=1
fi
[[ "$ret_ok" -eq 0 ]] && missing+=("retirement-condition")

# ADR-002 subtraction gate: require retire PR MERGED (state, not string-only) OR explicit N/A
sub_ok=0
if printf '%s' "$PR_BODY_EVIDENCE" | grep -qiE 'H5-SUBTRACTION:\s*N/?A'; then
  sub_ok=1
fi
retire_pr="$(printf '%s' "$PR_BODY" | grep -oiE 'H5-RETIRE-PR:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
if [[ -n "$retire_pr" ]]; then
  if command -v gh >/dev/null 2>&1; then
    st="$(gh pr view "$retire_pr" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    if [[ "$st" == "MERGED" ]]; then
      sub_ok=1
      log "H5: subtraction PR #$retire_pr state=MERGED"
    else
      fail "subtraction PR #$retire_pr state=$st (need MERGED)"
      missing+=("subtraction-pr-not-merged")
    fi
  else
    warn "gh unavailable; cannot verify H5-RETIRE-PR:$retire_pr state"
    missing+=("subtraction-pr-unverified")
  fi
fi
if [[ "$sub_ok" -eq 0 ]] && ! printf '%s' "${missing[*]-}" | grep -q subtraction; then
  missing+=("subtraction-gate")
fi

# Fail-open structural smell (warn only) on changed shell hooks
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  [[ "$f" != hooks/* ]] && continue
  # crude: catch "|| true" / "|| :" after critical decision paths + "exit 0" in error handlers
  if grep -nE '\|\|\s*(true|:)\s*$' "$f" | grep -qiE 'jq|curl|gh |git ' ; then
    warn "possible fail-open (command || true) in $f — review manually"
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES")"

if [[ -n "${missing[*]-}" ]]; then
  fail "admission fee incomplete: ${missing[*]}"
  if printf '%s' "${missing[*]}" | grep -q 'subtraction'; then
    fail "Required subtraction declaration: H5-SUBTRACTION: N/A OR H5-RETIRE-PR: <merged PR number>"
  fi
  fail "Required: (1) 陰性テスト red 実測記録 (2) H6 台帳配線 (3) 廃止条件宣言 — in PR body and/or code"
  fail "See design/ops/harness/h5-negative-test-gate.md"
  append_h5_block "negative-test-missing" "${missing[*]}"
  exit 1
fi

log "H5-PASS: 3-point admission fee present (negative-test + ledger + retirement)"
exit 0
