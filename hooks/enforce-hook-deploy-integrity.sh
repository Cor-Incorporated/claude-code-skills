#!/bin/bash
# enforce-hook-deploy-integrity.sh — SessionStart hook: enforce hook deployment integrity
# =========================================================================
# Successor to validate-hook-deployment.sh (archived to hooks/_unused/ per ADR-006):
#   1. MD5 comparison of hooks/*.sh vs ~/.claude/hooks/*.sh (report only)
#   2. Detect orphan deployed hooks (in ~/.claude/hooks/ but not in hooks/)
#   3. Check settings.json registration
#   NO auto-sync (loop-break T2): never cp from checkout branch into deploy dir
#
# SessionStart hook — cannot block (exit 0 always)
# stdout: JSON additionalContext (when issues found)
# stderr: diagnostic information
#
# Ref: Issue #183 — Hook deployment integrity enforcement
# Ref: Epic #130 — hookデプロイメント検証の構造的欠陥
# =========================================================================
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# --- Known exclusions (not directly registered in settings.json) ---
# aidd-h3-evidence-check.sh: CLI helper (stdin/file report); Stop path is aidd-h3-evidence-stop.sh
# lib/*: support libraries sourced by hooks, not SessionStart/PreToolUse entries
EXCLUDED_FROM_REGISTRATION=(
  "README.md"
  "aidd-h3-evidence-check.sh"
  "lib/aidd-ledger.sh"
  "aidd-ledger.sh"
)

# --- Known orphans (exist in ~/.claude/hooks/ but not in hooks/) ---
# Empty as of ADR-006 (minimal safety net) — retired hooks/gate-modes are
# pruned by setup.sh, not suppressed here.
KNOWN_ORPHANS=()

# --- Locate project hooks directory ---
# DANGER (2026-09-01): a bare -d test matches ANY repo that happens to own a
# directory named `hooks/`. aidd-governance ships `hooks/pre-commit` for
# `git config core.hooksPath` — a *git* hooks dir, not a Claude Code one. With
# CLAUDE_PROJECT_DIR pointing there, the first candidate won, every correctly
# deployed hook failed the Phase 3 `-f` test, and this hook reported
# "UNKNOWN ORPHAN" x20 plus the remedy "checkout develop && bash setup.sh".
# Acting on that remedy re-enacts the 2026-07-22 hook-loss incident
# (aidd-governance design/reduction-proposals.md:171-176), which is why
# reduction-proposals.md:47 already labelled this hook a 誤診生産装置.
# A directory only counts as a Claude Code hooks dir if it carries this sentinel.
HOOKS_DIR_SENTINEL="git-push-guard.sh"
PROJECT_HOOKS_DIR=""
for candidate in \
  "${CLAUDE_PROJECT_DIR:-}/hooks" \
  "$HOME/Developer/claude-code-skills/hooks" \
; do
  if [[ -d "$candidate" && -f "$candidate/$HOOKS_DIR_SENTINEL" ]]; then
    PROJECT_HOOKS_DIR="$candidate"
    break
  fi
done

# --- Phase 0: H1 no-progress visibility (T7-2) ---
# NOT a block: the stall signal lives outside agent turns, so no same-turn
# consequence is possible (proposition-enforcement-narrowing.md 区分D).
# Visibility only — heartbeat row every SessionStart; if the previous H1 row
# is >= 45 min old, append a no-progress-timeout warn row first.
# Spec: aidd-governance design/harness-spec.md H1
_H1_LEDGER="${HOME}/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$(dirname "$_H1_LEDGER")" 2>/dev/null || true
_H1_LAST_TS=""
if [[ -f "$_H1_LEDGER" ]]; then
  _H1_LAST_TS="$(python3 - "$_H1_LEDGER" <<'PY'
import json, sys
last = ""
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("component") == "H1":
        last = row.get("ts", "")
print(last)
PY
)"
  if [[ -n "$_H1_LAST_TS" ]]; then
    _H1_AGE="$(python3 - "$_H1_LAST_TS" <<'PY'
import sys
from datetime import datetime, timezone
try:
    last = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
except Exception:
    print("-1")
    sys.exit(0)
print(int((datetime.now(timezone.utc) - last).total_seconds()))
PY
)"
    if [[ "${_H1_AGE:-0}" -ge 2700 ]]; then
      if declare -F aidd_ledger_append >/dev/null 2>&1; then
        aidd_ledger_append "enforce-hook-deploy-integrity" "warn" "warn" \
          "${_H1_AGE}s since last H1 heartbeat (45min threshold)" \
          "no-progress-timeout" "H1"
      fi
    fi
  fi
fi
if declare -F aidd_ledger_append >/dev/null 2>&1; then
  aidd_ledger_append "enforce-hook-deploy-integrity" "measure" "allow" \
    "session start HB" "heartbeat" "H1"
fi

# --- core.hooksPath override that silently drops guards -----------------------
#
# 起点事故 (2026-09-02): 監督のプローブが `set -e` 無しでサンドボックスへの `cd` に
# 失敗し、続く `git config core.hooksPath /dev/null` が **実リポの
# aidd-governance に当たった。** 以後この repo の commit は pre-commit（H16 秘密
# 走査）を一度も通っていない。事後走査では流出は無かったが、**気づいたのは
# 別件を調べていた偶然**であって、装置は何も言わなかった。
#
# 同日、claude-code-skills も local override が `<repo>/.git/hooks`（`.sample`
# のみ）を指しており、global の pre-commit を影にしていた。こちらは誰が設定したか
# 特定できなかった。**設定した本人が気づけない**のが本欠陥の性質である。
#
# 判定: **local override が global より hook を減らしているか。**
#   - 「pre-commit が無い」だけでは撃たない。pre-commit を持たない repo は正当に
#     多く、そこで撃つと雑音になる。雑音はガードが読まれなくなる最短路である。
#   - global が提供する hook を override が落としているときだけ撃つ。これは
#     「守りが減った」ことの直接の観測であって、好みの問題ではない。
#
# 誤検知面を実測してから入れた (2026-09-02, $HOME/Developer 配下 58 repo):
#   override 有り 7 / うち失うもの有り 6 / 誤検知 0
#   opencode の `.husky/_` は 5 hook すべて持つので撃たない（正しく OK）
#   4 repo が pre-commit を完全に失っていた = 秘密走査が commit 時に走らない
#
# SessionStart は block できない。したがって出力は**実行可能な修復コマンド**に
# する（runbook.md 実値主義: 「適切に直す」ではなく、貼れば直る 1 行を出す）。
_ghp="$(git config --global core.hooksPath 2>/dev/null || true)"
_lhp="$(git -C "${CLAUDE_PROJECT_DIR:-.}" config --local core.hooksPath 2>/dev/null || true)"
if [[ -n "$_ghp" && -n "$_lhp" && -d "$_ghp" ]]; then
  case "$_lhp" in
    /*) _lhp_abs="$_lhp" ;;
    *)  _lhp_abs="${CLAUDE_PROJECT_DIR:-.}/$_lhp" ;;
  esac
  _lost=""
  for _h in "$_ghp"/*; do
    [[ -f "$_h" ]] || continue
    _hn="$(basename "$_h")"
    case "$_hn" in *.sample) continue ;; esac
    [[ -x "$_lhp_abs/$_hn" ]] || _lost="${_lost}${_lost:+ }${_hn}"
  done
  if [[ -n "$_lost" ]]; then
    echo "[Hook Deploy Integrity] core.hooksPath の local override が global の hook を落としています。" >&2
    echo "  repo   : ${CLAUDE_PROJECT_DIR:-$PWD}" >&2
    echo "  local  : ${_lhp}" >&2
    echo "  global : ${_ghp}" >&2
    echo "  失う   : ${_lost}" >&2
    echo "  FIX    : git -C '${CLAUDE_PROJECT_DIR:-$PWD}' config --local --unset core.hooksPath" >&2
    # override 先が hook を置けない場所（/dev/null 等）のとき「そこへ配置しろ」は
    # 実行不可能な助言になる。runbook.md 実値主義 — 出す手順は実行できるものだけ。
    if [[ -d "$_lhp_abs" ]]; then
      echo "  （override が意図的なら、落ちている hook を ${_lhp_abs}/ へ配置してください）" >&2
    else
      echo "  （'${_lhp}' はディレクトリではないので hook を置けません。unset が唯一の修復です）" >&2
    fi
    if declare -F aidd_ledger_append >/dev/null 2>&1; then
      aidd_ledger_append "enforce-hook-deploy-integrity" "warn" "warn" \
        "local hooksPath override drops: ${_lost}" "hookspath-override-drops-guards"
    fi
  fi
fi
unset _ghp _lhp _lhp_abs _lost _h _hn

# No sentinel-bearing hooks dir => no baseline to diff against. Skip, but say so:
# a silent skip is indistinguishable from a clean run, and "clean" is the one
# conclusion we must not imply when the comparison never happened.
if [[ -z "$PROJECT_HOOKS_DIR" ]]; then
  echo "[Hook Deploy Integrity] SKIPPED — no Claude Code hooks dir found (sentinel '${HOOKS_DIR_SENTINEL}' absent in '${CLAUDE_PROJECT_DIR:-unset}/hooks' and '$HOME/Developer/claude-code-skills/hooks'). No conclusion about deploy integrity." >&2
  exit 0
fi

INSTALLED_HOOKS_DIR="$HOME/.claude/hooks"
CODEX_HOOKS_DIR="$HOME/.codex/hooks"
CURSOR_HOOKS_DIR="$HOME/.cursor/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

# --- Helper: resolve each repository hook to its tool-specific deploy root ---
# hooks/codex/* and hooks/cursor/* are version-controlled beside Claude hooks,
# but setup.sh deploys them to their own tool homes.  They must not be checked
# as if the nested directory also existed below ~/.claude/hooks.
deployed_hook_path() {
  local rel_path="$1"
  case "$rel_path" in
    codex/*) printf '%s/%s\n' "$CODEX_HOOKS_DIR" "${rel_path#codex/}" ;;
    cursor/*) printf '%s/%s\n' "$CURSOR_HOOKS_DIR" "${rel_path#cursor/}" ;;
    *) printf '%s/%s\n' "$INSTALLED_HOOKS_DIR" "$rel_path" ;;
  esac
}

# --- Helper: check if a filename is in the exclusion list ---
is_excluded() {
  local filename="$1"
  for excluded in "${EXCLUDED_FROM_REGISTRATION[@]}"; do
    if [[ "$filename" == "$excluded" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: check if a filename is a known orphan ---
is_known_orphan() {
  local filename="$1"
  for orphan in "${KNOWN_ORPHANS[@]:-}"; do
    [[ -z "$orphan" ]] && continue
    if [[ "$filename" == "$orphan" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: compute md5 hash (macOS md5 / Linux md5sum) ---
compute_md5() {
  local filepath="$1"
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$filepath" 2>/dev/null
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$filepath" 2>/dev/null | awk '{print $1}'
  else
    echo "NO_MD5_COMMAND"
  fi
}

issues=()

# --- Phase 1: Collect project hook files ---
# PROJECT_HOOKS_DIR is guaranteed non-empty here (sentinel check + exit above).
project_files=()
while IFS= read -r -d '' filepath; do
  # Preserve relative path from PROJECT_HOOKS_DIR (e.g. gate-modes/stop.sh)
  rel_path="${filepath#$PROJECT_HOOKS_DIR/}"
  project_files+=("$rel_path")
done < <(find "$PROJECT_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)

# --- Phase 2: MD5 compare + report only (NO auto-sync cp) ---
# loop-break T2: auto-sync copied from whichever branch was checked out at
# SessionStart and re-deployed retired hooks (main 52 → disk 63). Detect only.
for rel_path in "${project_files[@]}"; do
  repo_file="$PROJECT_HOOKS_DIR/$rel_path"
  deployed_file=$(deployed_hook_path "$rel_path")

  if [[ ! -f "$deployed_file" ]]; then
    issues+=("NOT INSTALLED: $rel_path (target=${deployed_file}; detect-only; run setup.sh from develop)")
    continue
  fi

  # Both files exist — compare MD5 (do not copy)
  repo_md5=$(compute_md5 "$repo_file")
  deployed_md5=$(compute_md5 "$deployed_file")

  if [[ "$repo_md5" != "$deployed_md5" ]]; then
    issues+=("MD5 MISMATCH: $rel_path (repo=${repo_md5} deployed=${deployed_md5} target=${deployed_file}; no auto-sync)")
  fi
done

# --- Phase 3: Detect orphan deployed hooks ---
if [[ -d "$INSTALLED_HOOKS_DIR" ]]; then
  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files and support libs (not standalone hooks)
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac
    case "$rel_path" in
      lib/*) continue ;;
    esac

    # Check if this deployed file exists in project hooks
    if [[ ! -f "$PROJECT_HOOKS_DIR/$rel_path" ]]; then
      if is_known_orphan "$filename"; then
        issues+=("KNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      else
        issues+=("UNKNOWN ORPHAN: $rel_path (in ~/.claude/hooks/ but not in hooks/)")
      fi
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' -not -path '*/lib/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 4: Check settings.json registration ---
if [[ -f "$SETTINGS_FILE" ]]; then
  settings_content=$(cat "$SETTINGS_FILE")

  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$INSTALLED_HOOKS_DIR/}"
    filename=$(basename "$filepath")

    # Skip non-script files and support libs
    case "$filename" in
      README.md|*.pyc) continue ;;
    esac
    case "$rel_path" in
      lib/*) continue ;;
    esac

    # Skip known exclusions
    if is_excluded "$rel_path" || is_excluded "$filename"; then
      continue
    fi

    # Check if registered in settings.json
    if ! echo "$settings_content" | grep -q "~/.claude/hooks/$rel_path"; then
      issues+=("NOT REGISTERED: $rel_path (not in settings.json)")
    fi
  done < <(find "$INSTALLED_HOOKS_DIR" -not -path '*/_unused/*' -not -path '*/__pycache__/*' -not -path '*/lib/*' \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)
fi

# --- Phase 4b: Codex hook trust state (Issue #103) ---
# The three deploy requirements (file exists / copied into ~/.codex/hooks /
# registered in hooks.json) are NOT sufficient for Codex. config.toml carries a
# per-position trust entry, and a registered hook without active trust is skipped
# SILENTLY -- no error, no log line.
# 2026-09-01: protect-branches-codex.sh satisfied all three requirements and still
# fired zero times for 19 days, because its entry said `enabled = false`.
# Trust is keyed by POSITION ("<event>:<matcher>:<hook>"), so inserting a hook also
# invalidates whatever used to occupy that index.
# Warn only -- this hook never mutates another tool's configuration.
_CODEX_HOOKS_JSON="$HOME/.codex/hooks.json"
_CODEX_CONFIG="$HOME/.codex/config.toml"
if [[ -f "$_CODEX_HOOKS_JSON" && -f "$_CODEX_CONFIG" ]] && command -v python3 >/dev/null 2>&1; then
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && issues+=("$_line")
  done < <(python3 "$(dirname "${BASH_SOURCE[0]}")/lib/codex-trust-state.py" \
             "$_CODEX_HOOKS_JSON" "$_CODEX_CONFIG" 2>/dev/null || true)
fi

# --- Phase 5: Output results (warn only; never mutate deploy dir) ---
if [[ ${#issues[@]} -gt 0 ]]; then
  issue_count=${#issues[@]}

  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "enforce-hook-deploy-integrity" "warn" "warn" "issues=${issue_count}" "hook-deploy-integrity"
  fi

  # stderr: diagnostic output
  echo "[Hook Deploy Integrity] ${issue_count} issues found:" >&2
  for issue in "${issues[@]}"; do
    echo "  - ${issue}" >&2
  done
  echo "[Hook Deploy Integrity] detect-only (no auto-sync). Fix: checkout develop && bash setup.sh" >&2

  # Build warning message for additionalContext
  warning_lines=""
  for issue in "${issues[@]}"; do
    warning_lines="${warning_lines}\\n- ${issue}"
  done
  message="[Hook Deploy Integrity] ${issue_count} issues found:${warning_lines}\\n(detect-only; no auto-sync)"

  # stdout: JSON additionalContext
  python3 -c "
import json, sys
msg = sys.argv[1]
output = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': msg
    }
}
print(json.dumps(output))
" "$message"
fi

exit 0
