#!/bin/bash
# Codex PreToolUse: protect branches (main/master/develop) from direct/force push.
# Port of Claude Code protect-branches.sh cmd_norm / _GIT_PUSH_RE / Check 0a/0a2
# and Cursor git-guard.sh direct-push rules — NOT execpolicy prefix_rule.
#
# Input: JSON on stdin (tool_input.command | tool_input.cmd | command)
# Output: hookSpecificOutput.permissionDecision deny, or {} on allow
# Exit: 0 (Codex fails open on a non-zero hook exit)
#
# Scope: destructive git push/merge forms and explicit foreign-owner PR targets.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '
  .tool_input.command
  // .tool_input.cmd
  // .tool_input.shell_command
  // .command
  // .cmd
  // empty
' 2>/dev/null || true)
cmd=${cmd:-}

PROTECTED="main master develop"
LEDGER="${CODEX_GUARD_LEDGER:-$HOME/.codex/hooks/guard-ledger.jsonl}"

# Normalise before matching. cmd_norm is used ONLY for detection, never for
# execution, so it is safe to be aggressive here — the failure direction that
# matters is a guard that silently misses, not one that inspects too much.
#
# 2026-09-02 実測: Codex Desktop は UI 由来のテキストを Markdown エスケープした
# まま hook へ渡す。実物は ["/bin/zsh","-lc","echo AIDD\_CODEX\_HOOK\_SPIKE\_MARKER"]。
# 素の文字列比較だと `\-\-repo` が `--repo` に一致せず、他所リポへの PR 検出が
# ALLOW に転んでいた（保護ブランチ判定は main/master/develop に punctuation が
# 無いため影響を受けていなかった）。
# 対策: 引用符の除去に加えて、Markdown がエスケープしうる記号の前の
# バックスラッシュを外してから照合する。
cmd_norm=$(printf '%s' "$cmd" \
  | tr -d "\"'" \
  | sed -E 's/\\([_*`~|[:punct:]])/\1/g')
_GIT_PUSH_RE='(^|[^[:alnum:]_-])git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*push([^[:alnum:]_-]|$)'

emit_deny() {
  local msg="$1"
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
  printf '{"ts":"%s","hook":"protect-branches-codex","decision":"deny","cmd_head":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$cmd" | head -c 120 | tr '"' "'")" \
    >>"$LEDGER" 2>/dev/null || true
  # Codex operational shape: permissionDecision deny
  # Codex acts on permissionDecision=deny with exit 0.
  # Non-zero exit is treated as hook failure and may fail-open (spike 2026-08-11).
  jq -n --arg m "$msg" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }' 2>/dev/null || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$msg"
  exit 0
}

emit_allow() {
  printf '%s\n' '{}'
  exit 0
}

# Spike probe marker (harmless; used only for fire test)
if printf '%s' "$cmd_norm" | grep -q 'AIDD_CODEX_HOOK_SPIKE_MARKER'; then
  printf 'SPIKE_FIRED %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${CODEX_SPIKE_LOG:-$HOME/.codex/hooks/spike-fire.log}" 2>/dev/null || true
  emit_deny "AIDD Codex hook spike: PreToolUse fired (probe marker)"
fi

# Read-only inspectors that merely mention git push (CC protect-branches skip)
if [[ -n "$cmd" ]] \
  && [[ "$cmd" != *$'\n'* ]] \
  && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
  && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  emit_allow
fi

# Foreign repository PR target gate (Phase 16 T16-2).
# Codex 0.147.0 did not interpret permissionDecision=ask in an actual
# PreToolUse spike, so this port uses deny plus guidance. Legitimate OSS PRs
# remain possible by running gh from a worktree whose origin owner matches the
# explicit --repo owner. No --repo remains out of scope.
if printf '%s' "$cmd_norm" | grep -qE '(^|[^[:alnum:]_/-])gh[[:space:]]+pr[[:space:]]+(create|merge)([^[:alnum:]_-]|$)'; then
  pr_repo=$(printf '%s\n' "$cmd_norm" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "--repo" && i < NF) { print $(i + 1); exit }
        if ($i ~ /^--repo=/) { sub(/^--repo=/, "", $i); print $i; exit }
      }
    }
  ')
  if [[ -n "$pr_repo" ]]; then
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    origin_slug=$(printf '%s' "$origin_url" \
      | sed -E 's#^git@[^:]+:##; s#^ssh://git@[^/]+/##; s#^https?://[^/]+/##; s#\.git$##')
    origin_owner="${origin_slug%%/*}"
    target_slug=$(printf '%s' "$pr_repo" \
      | sed -E 's#^https?://github\.com/##; s#^github\.com/##; s#\.git$##')
    target_owner="${target_slug%%/*}"
    origin_owner_lc=$(printf '%s' "$origin_owner" | tr '[:upper:]' '[:lower:]')
    target_owner_lc=$(printf '%s' "$target_owner" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$origin_owner_lc" && -n "$target_owner_lc" && "$origin_owner_lc" != "$target_owner_lc" ]]; then
      emit_deny "PR target owner '${target_owner}' differs from origin owner '${origin_owner}'. Codex ask is unsupported; run this contribution from a worktree of the target repository."
    fi
  fi
fi

# Only git push / merge
if ! printf '%s' "$cmd_norm" | grep -qE "$_GIT_PUSH_RE" \
  && ! printf '%s' "$cmd_norm" | grep -qE '\bgit[[:space:]]+merge\b'; then
  emit_allow
fi

current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

is_protected() {
  case " $PROTECTED " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}

# Match protected branch as refspec destination or bare token
# Covers: main, HEAD:main, +HEAD:main, +refs/heads/main, refs/heads/main, origin main, -u origin main
ref_targets_protected() {
  printf '%s' "$cmd_norm" | grep -qE '(^|[[:space:]:/])(refs/heads/)?(main|master|develop)([[:space:]]|$)'
}

if printf '%s' "$cmd_norm" | grep -qE '\bgit[[:space:]]+merge\b'; then
  if is_protected "$current"; then
    emit_deny "保護ブランチ '${current}' への直接 merge は禁止です。PR 経由でマージしてください。"
  fi
fi

if printf '%s' "$cmd_norm" | grep -qE "$_GIT_PUSH_RE"; then
  if printf '%s' "$cmd_norm" | grep -qE '[[:space:]]--(all|mirror)([^[:alnum:]_-]|$)'; then
    emit_deny "--mirror/--all 付き push は禁止です（全 ref の上書き・削除になり得ます）。"
  fi
  # Check 0a2: refspec force +<ref> (after space or colon)
  if printf '%s' "$cmd_norm" | grep -qE '[[:space:]:]\+[A-Za-z0-9_./-]'; then
    emit_deny "refspec force (+<ref>) 付き push は禁止です（--force と等価）。"
  fi
  if printf '%s' "$cmd_norm" | grep -qE '(\-\-force([^-]|$)|[[:space:]]-[a-zA-Z]*f([[:space:]]|$)|--force-with-lease)'; then
    if ref_targets_protected || is_protected "$current"; then
      emit_deny "保護ブランチへの force-push は禁止です。feature ブランチで作業し PR を出してください。"
    fi
  fi
  # Direct push to protected (force or not) — closes HEAD:main / +refs/heads/main etc.
  if ref_targets_protected || is_protected "$current"; then
    emit_deny "保護ブランチ(main/master/develop)への直接 push は禁止です。feature ブランチで作業し PR を出してください。"
  fi
fi

emit_allow
