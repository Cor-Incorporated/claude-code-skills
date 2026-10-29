#!/usr/bin/env bash
# harness-guardrail-ledger.sh — PostToolUse:Bash bridge
# =========================================================================
# claude-code-harness plugin の RUNTIME_FLOOR / R01〜R13 の発火を
# ADR-006 の防御台帳 (~/.claude/hooks/ledger/guard-ledger.jsonl) へ写す。
#
# なぜ要るか (2026-10-30 harness-pdca F3):
#   床は third-party plugin (Chachamaru127/claude-code-harness) の Go 実装で、
#   発火は <project>/.claude/state/audit/guardrail-fires.jsonl にだけ書かれる。
#   一晩で 9 レーン中 6 レーンが床に当たったが、guard-ledger.jsonl には 0 行
#   だった。H6 の退役判定 (90 日発火ゼロ / 誤検知率 50% 超) は guard-ledger を
#   読むので、床は「一度も発火していない」と同じに見えていた。
#   床の deny は PostToolUseFailure を発火しない (2026-10-30 実測: deny した
#   tool_use_id に PostToolUseFailure の attachment が無い)。だから失敗 hook では
#   拾えず、plugin の監査ファイルを次の Bash 呼び出しで取り込む。
#
# 方式:
#   1. 入力 cwd から plugin と同じ規則で project root を求める
#      (.git か .harness を持つ最も近い祖先。$HOME より上へは昇らない。
#       見つからなければ cwd。go/internal/guardrail/pre_tool.go ascendToProjectRoot)
#   2. 監査ファイルの大きさが前回の cursor と同じなら即 exit 0 (stat だけ)
#   3. 増えていれば lock を取り、cursor を先に進めてから新しい行を台帳へ追記する
#      (at-most-once。重複より欠落を選ぶ: 2 セッションが同じ project で同時に
#       取り込んでも二重計上しない)
#
# 台帳に生コマンドは載せない。plugin 自身が secret-read / money-billing では
# コマンドの hash すら残さない設計で、ここも rule_id と category だけ写す。
#
# 失敗時は黙って exit 0 (観測が tool の結果を変えてはならない)。
#
# 廃止条件: plugin が guard-ledger.jsonl へ直接書くようになった時点、または
#   harness plugin を外した時点で退役。90 日間 bridge 経由の行が 0 なら退役 issue。
# =========================================================================
set -uo pipefail

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LEDGER_LIB="$_HOOK_DIR/lib/aidd-ledger.sh"
[ -f "$_LEDGER_LIB" ] || exit 0
# shellcheck source=/dev/null
. "$_LEDGER_LIB"
command -v python3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=""
if [[ ! -t 0 ]]; then
  input="$(cat 2>/dev/null || true)"
fi
[[ -z "$input" ]] && exit 0

cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
[[ -z "$cwd" ]] && cwd="$PWD"
[[ -d "$cwd" ]] || exit 0
# One audit file must map to one cursor whatever spelling the cwd has
# (/tmp vs /private/tmp, a trailing slash, a symlinked checkout).
cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || exit 0

# plugin と同じ root 解決 (pre_tool.go ascendToProjectRoot)
resolve_root() {
  local dir="$1" home
  home="$(cd "$HOME" 2>/dev/null && pwd -P)" || home="${HOME%/}"
  local d="$dir"
  while [[ -n "$d" && "$d" != "/" && "$d" != "$home" ]]; do
    if [[ -e "$d/.git" || -e "$d/.harness" ]]; then
      printf '%s' "$d"
      return
    fi
    d="$(dirname "$d")"
  done
  printf '%s' "$dir"
}

root="$(resolve_root "$cwd")"
audit="$root/.claude/state/audit/guardrail-fires.jsonl"
[[ -f "$audit" ]] || exit 0
# A tracked audit file came in with a clone; its rows are not fires here.
if git -C "$root" ls-files --error-unmatch -- ".claude/state/audit/guardrail-fires.jsonl" >/dev/null 2>&1; then
  exit 0
fi

cursor_dir="${AIDD_GUARDRAIL_CURSOR_DIR:-$HOME/.claude/hooks/ledger/harness-cursors}"
mkdir -p "$cursor_dir" 2>/dev/null || exit 0
key="$(printf '%s' "$audit" | shasum -a 256 2>/dev/null | cut -c1-24)"
[[ -n "$key" ]] || exit 0
cursor_file="$cursor_dir/$key"

size="$(wc -c <"$audit" 2>/dev/null | tr -d ' ')"
if [[ -f "$cursor_file" ]]; then
  last="$(cut -d' ' -f1 <"$cursor_file" 2>/dev/null)"
  [[ "$last" == "$size" ]] && exit 0
fi

records="$(python3 - "$audit" "$cursor_file" "$root" <<'PY' 2>/dev/null
import fcntl
import json
import os
import sys

audit, cursor_file, root = sys.argv[1:]
lock = open(cursor_file + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    offset, inode = 0, None
    try:
        with open(cursor_file) as fh:
            parts = fh.read().split()
        offset = int(parts[0])
        inode = int(parts[1]) if len(parts) > 2 and parts[1].isdigit() else None
    except (OSError, ValueError, IndexError):
        offset = 0
    st = os.stat(audit)
    size = st.st_size
    if offset > size or (inode is not None and inode != st.st_ino):
        offset = 0  # truncated, rotated or replaced
    with open(audit, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read(min(size - offset, 1 << 20))
    end = chunk.rfind(b"\n")
    if end < 0:
        raise SystemExit(0)
    chunk = chunk[: end + 1]
    tmp = cursor_file + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(f"{offset + len(chunk)} {st.st_ino} {audit}\n")
    os.replace(tmp, cursor_file)
finally:
    fcntl.flock(lock, fcntl.LOCK_UN)
    lock.close()

agents = {"claude": "claude-code", "codex": "codex", "cursor": "cursor", "opencode": "opencode"}
for raw in chunk.decode("utf-8", "replace").splitlines():
    try:
        fire = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if not isinstance(fire, dict) or fire.get("schema_version") != "guardrail-fire.v1":
        continue
    rule = str(fire.get("rule_id") or "unknown")
    decision = str(fire.get("decision") or "unknown")
    category = str(fire.get("category") or "")
    tool = str(fire.get("tool") or "")
    record = {
        "component": "H6",
        "hook": "harness-guardrail",
        "event": "block" if decision == "deny" else "measure",
        "decision": decision,
        "rule": rule,
        "cmd_head": f"{tool} {category or rule}".strip(),
        "bridge": "harness-guardrail-ledger",
        "audit_root": root,
        "agent": agents.get(str(fire.get("host") or ""), str(fire.get("host") or "unknown")),
    }
    if fire.get("ts"):
        record["ts"] = str(fire["ts"])
    if category:
        record["category"] = category
    print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
PY
)"

[[ -n "$records" ]] || exit 0
printf '%s\n' "$records" | aidd_ledger_append_records >/dev/null 2>&1 || true
exit 0
