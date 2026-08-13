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
  safe_cmd="$(printf '%s' "$cmd_head" | head -c 120 | tr '"' "'" | tr '\n' ' ')"
  local safe_session
  safe_session="$(printf '%s' "$session" | head -c 80 | tr '"' "'" | tr '\n' ' ')"
  if [[ "$component" == "H1" ]]; then
    printf '{"ts":"%s","component":"H1","event":"%s","rule":"%s","detail":"%s","subject":{},"source":"%s","session":"%s","agent":"%s"}\n' \
      "$ts" "$event" "$rule" "$safe_cmd" "$source" "$safe_session" "$agent" >>"$ledger" 2>/dev/null || true
  else
    printf '{"ts":"%s","component":"%s","hook":"%s","event":"%s","decision":"%s","rule":"%s","cmd_head":"%s","source":"%s","session":"%s","agent":"%s"}\n' \
      "$ts" "$component" "$hook" "$event" "$decision" "$rule" "$safe_cmd" "$source" "$safe_session" "$agent" >>"$ledger" 2>/dev/null || true
  fi
}
