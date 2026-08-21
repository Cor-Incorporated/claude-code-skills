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
  git fetch --no-tags --depth=1 origin "$(echo "$BASE_REF" | sed 's#^origin/##')" 2>/dev/null || true
  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    DIFF_FILES="$(git diff --name-only "$BASE_REF"...$HEAD_REF 2>/dev/null || git diff --name-only "$BASE_REF" $HEAD_REF 2>/dev/null || true)"
  else
    DIFF_FILES="$(git diff --name-only HEAD~1...HEAD 2>/dev/null || true)"
  fi
fi

is_guard_pr=0
# Structural triggers: any path that can change guard force projection.
# Keep this set and the H5-guard:no exemption-denylist (below) IDENTICAL.
# Phase 5 T5-2: must cover hooks/lib/** and scripts/** (.+\.sh), not only hooks/[^/]+\.sh
# Checklist S9 expects this form (hooks/.+\.sh includes hooks/lib/*.sh).
_H5_STRUCT_RE='^(hooks/.+\.sh|scripts/.+\.sh|settings\.json|\.github/workflows/)'
if printf '%s\n' "$DIFF_FILES" | grep -qE "$_H5_STRUCT_RE"; then
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
  if ! printf '%s\n' "$DIFF_FILES" | grep -qE "$_H5_STRUCT_RE"; then
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
)
_H8_FIELD_NAMES=(
  "一次資料"
  "要求インベントリ"
  "突合表"
  "標準質問"
  "北極星"
  "反証軸"
  "撤収"
)
h8_docs=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if printf '%s' "$f" | grep -qE "$_H8_DOC_RE" && [[ -f "$f" ]]; then
    h8_docs+=("$f")
  fi
done <<<"$(printf '%s\n' "$DIFF_FILES")"

h8_missing=()
if [[ -n "${h8_docs[*]-}" ]]; then
  for f in "${h8_docs[@]}"; do
    grep -qE '委任契約|要求インベントリ' "$f" || continue
    for ((h8_i = 0; h8_i < ${#_H8_FIELDS[@]}; h8_i++)); do
      field="${_H8_FIELDS[$h8_i]}"
      field_name="${_H8_FIELD_NAMES[$h8_i]}"
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
fi

# Ignore negation/meta lines so "missing 陰性テスト" does not count as evidence.
# H5-E2E remains a form declaration only: this script cannot prove that the
# command or output is truthful (T8-4).
PR_BODY_EVIDENCE="$(printf '%s\n' "$PR_BODY" | grep -viE \
  'intentionally missing|expect red|do not merge|falsification only|未記入|TODO 陰性|TODO 台帳|TODO 廃止' || true)"

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
