#!/usr/bin/env bash
# H6 defense ledger helper (append-only JSONL)
# T9-2: "source":"real"|"test" — AIDD_LEDGER_SOURCE=test なら test、未設定なら real
#（既定は安全側 = real。テストハーネスが hook を叩く箇所で export すること）
# shellcheck disable=SC2034
# Truncate to at most N bytes WITHOUT leaving a half-written UTF-8 character.
# `head -c` cuts bytes, so a multi-byte character (Japanese command text, for
# example) can be sliced in half and the row becomes invalid UTF-8.
# 2026-09-01 実測: 本番台帳 4841 行のうち 2 行 (2026-08-10) がこれで壊れていた。
# 実害は限定的 — /usr/bin/grep も scripts/ledger-summary.sh (python3) も正常に
# 読める。ただし監査ログに不正なバイト列を残す理由はない。
# iconv -c は末尾の不完全シーケンスを落とす。iconv が無い環境では従来動作。
_aidd_truncate_utf8() {
  local limit="${1:-120}"
  if command -v iconv >/dev/null 2>&1; then
    head -c "$limit" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
  else
    head -c "$limit"
  fi
}

aidd_ledger_append() {
  local hook="${1:-unknown}"
  local event="${2:-block}"
  local decision="${3:-deny}"
  local cmd_head="${4:-}"
  local rule="${5:-}"
  local component="${6:-H6}"
  local agent="${7:-claude-code}"
  local source="${AIDD_LEDGER_SOURCE:-real}"
  local session="${AIDD_LEDGER_SESSION:-unset}"
  local ledger_dir="${HOME}/.claude/hooks/ledger"
  local ledger="${ledger_dir}/guard-ledger.jsonl"
  mkdir -p "$ledger_dir"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  local safe_cmd
  safe_cmd="$(printf '%s' "$cmd_head" | _aidd_truncate_utf8 120 | tr '"' "'" | tr '\n' ' ')"
  local safe_session
  safe_session="$(printf '%s' "$session" | _aidd_truncate_utf8 80 | tr '"' "'" | tr '\n' ' ')"
  if [[ "$component" == "H1" ]]; then
    printf '{"ts":"%s","component":"H1","event":"%s","rule":"%s","detail":"%s","subject":{},"source":"%s","session":"%s","agent":"%s"}\n' \
      "$ts" "$event" "$rule" "$safe_cmd" "$source" "$safe_session" "$agent" >>"$ledger" 2>/dev/null || true
  else
    printf '{"ts":"%s","component":"%s","hook":"%s","event":"%s","decision":"%s","rule":"%s","cmd_head":"%s","source":"%s","session":"%s","agent":"%s"}\n' \
      "$ts" "$component" "$hook" "$event" "$decision" "$rule" "$safe_cmd" "$source" "$safe_session" "$agent" >>"$ledger" 2>/dev/null || true
  fi
}

# Append a structured measurement without truncating nested JSON values.
#
# Usage:
#   aidd_ledger_append_record '{"component":"H2","event":"measure",...}' [agent]
#
# Unlike aidd_ledger_append, this function reports validation and write errors to
# its caller.  Existing hook call sites intentionally keep using the legacy,
# best-effort helper above.
aidd_ledger_append_record() {
  local record_json="${1:-}"
  local agent="${2:-${AIDD_LEDGER_AGENT:-claude-code}}"
  local source="${AIDD_LEDGER_SOURCE:-real}"
  local session="${AIDD_LEDGER_SESSION:-unset}"
  local ledger="${AIDD_LEDGER_PATH:-${HOME}/.claude/hooks/ledger/guard-ledger.jsonl}"
  local ledger_dir
  ledger_dir="$(dirname "$ledger")"

  if ! mkdir -p "$ledger_dir"; then
    printf 'aidd-ledger: cannot create ledger directory: %s\n' "$ledger_dir" >&2
    return 1
  fi

  python3 - "$ledger" "$record_json" "$source" "$session" "$agent" <<'PY'
import datetime
import json
import os
import sys

ledger, raw, source, session, agent = sys.argv[1:]
try:
    record = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"aidd-ledger: invalid JSON record: {exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(record, dict):
    print("aidd-ledger: structured record must be a JSON object", file=sys.stderr)
    raise SystemExit(2)
for field in ("component", "event"):
    if not isinstance(record.get(field), str) or not record[field].strip():
        print(f"aidd-ledger: missing non-empty string field: {field}", file=sys.stderr)
        raise SystemExit(2)

record["source"] = source
record["session"] = session
record["agent"] = agent
record.setdefault(
    "ts",
    datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
)
line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"

try:
    fd = os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as stream:
        stream.write(line)
        stream.flush()
except OSError as exc:
    print(f"aidd-ledger: append failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}
