#!/usr/bin/env bash
# H6 defense ledger helper (append-only JSONL)
# T9-2: "source":"real"|"test" — AIDD_LEDGER_SOURCE=test なら test、未設定なら real
#（既定は安全側 = real。テストハーネスが hook を叩く箇所で export すること）
# shellcheck disable=SC2034
aidd_ledger_append() {
  local hook="${1:-unknown}"
  local event="${2:-block}"
  local decision="${3:-deny}"
  local cmd_head="${4:-}"
  local rule="${5:-}"
  local source="${AIDD_LEDGER_SOURCE:-real}"
  local ledger_dir="${HOME}/.claude/hooks/ledger"
  local ledger="${ledger_dir}/guard-ledger.jsonl"
  mkdir -p "$ledger_dir"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  local safe_cmd
  safe_cmd="$(printf '%s' "$cmd_head" | head -c 120 | tr '"' "'" | tr '\n' ' ')"
  printf '{"ts":"%s","component":"H6","hook":"%s","event":"%s","decision":"%s","rule":"%s","cmd_head":"%s","source":"%s","agent":"claude-code"}\n' \
    "$ts" "$hook" "$event" "$decision" "$rule" "$safe_cmd" "$source" >>"$ledger" 2>/dev/null || true
}
