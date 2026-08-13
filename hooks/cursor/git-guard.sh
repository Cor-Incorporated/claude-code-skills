#!/bin/bash
# Cursor beforeShellExecution フック:
#   保護ブランチ(main/master/develop)への force-push / 直接 push・merge を禁止する。
#   --mirror / --all / refspec force(+) も破壊形として deny。
# 注意: set -e は使わない（grep の非マッチ exit 1 で fail-closed 誤爆を防ぐ）。
#
# 4ツール横断の強制点の 1 つ。他: ~/.claude/hooks/{git-push-guard,protect-branches}.sh /
# ~/.codex/rules/default.rules / ~/.config/opencode/opencode.jsonc permission
# 片方だけ変えない（cross-tool-scope-collapse / tests/test-cross-tool-force-matrix.sh）
set -uo pipefail

_LEDGER_LIB="${HOME}/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.command // ""' 2>/dev/null)

PROTECTED="main master develop"

# 引用形・空白ゆれ用の正規化（protect-branches.sh cmd_norm と同クラス）
cmd_norm=$(printf '%s' "$cmd" | tr -d "\"'")
# git [global-opts...] push
_GIT_PUSH_RE='(^|[^[:alnum:]_-])git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*push([^[:alnum:]_-]|$)'

# beforeShellExecution receives an entire shell program. Push rules must inspect
# only the segment that actually invokes `git push`; tokens from a later PR
# command (for example `gh pr create --base main`) are not push refspecs.
split_command_segments() {
  printf '%s\n' "$cmd_norm" | awk '{gsub(/&&|\|\||;/, "\n"); print}'
}

deny() {
  printf '{"ts":"%s","hook":"git-guard","decision":"deny","cmd_head":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$cmd" | head -c 120 | tr '"' "'")" \
    >> "$HOME/.cursor/hooks/guard-ledger.jsonl" 2>/dev/null || true
  jq -n --arg m "$1" '{permission:"deny", user_message:$m, agent_message:$m}' 2>/dev/null \
    || printf '{"permission":"deny","agent_message":"%s"}' "$1"
  exit 0
}
ask() {
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "cursor-git-guard" "warn" "warn" "$cmd" \
      "foreign-pr-repo" "H6" "cursor"
  fi
  jq -n --arg m "$1" '{permission:"ask", user_message:$m, agent_message:$m}' 2>/dev/null \
    || printf '{"permission":"ask","agent_message":"%s"}' "$1"
  exit 0
}
allow() { printf '{"permission":"allow"}'; exit 0; }

# `gh pr create/merge --repo` の owner が origin と異なる場合は、人間確認へ
# 回す。正当な OSS 貢献があるため deny にはしない。--repo なしは OC-D8
# の set-default が担当するため、この hook では対象外。
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
      ask "PR target owner '${target_owner}' differs from origin owner '${origin_owner}'. Confirm this cross-repository contribution."
    fi
  fi
fi

# git push / merge 以外は素通り
push_segments=""
while IFS= read -r segment; do
  if printf '%s' "$segment" | grep -qE "$_GIT_PUSH_RE"; then
    push_segments="${push_segments}${segment}
"
  fi
done < <(split_command_segments)

[[ -n "$push_segments" ]] \
  || printf '%s' "$cmd_norm" | grep -qE '\bgit[[:space:]]+merge\b' \
  || allow

current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

is_protected() {
  case " $PROTECTED " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}
ref_targets_protected() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]:/])(main|master|develop)([[:space:]]|$)'
}

# merge: 保護ブランチ上での直接マージを禁止
if printf '%s' "$cmd_norm" | grep -qE '\bgit[[:space:]]+merge\b'; then
  if is_protected "$current"; then
    deny "保護ブランチ '${current}' への直接 merge は禁止です。PR 経由でマージしてください。"
  fi
fi

# push の判定。区切られた各 push segment を独立に評価する。
while IFS= read -r push_segment; do
  [[ -n "$push_segment" ]] || continue
  # --mirror / --all（位置・引用に依存しない）
  if printf '%s' "$push_segment" | grep -qE '[[:space:]]--(all|mirror)([^[:alnum:]_-]|$)'; then
    deny "--mirror/--all 付き push は禁止です（全 ref の上書き・削除になり得ます）。"
  fi
  # refspec force +<ref>
  if printf '%s' "$push_segment" | grep -qE '[[:space:]:]\+[A-Za-z0-9_./-]'; then
    deny "refspec force (+<ref>) 付き push は禁止です（--force と等価）。"
  fi
  # force-push（--force / -f / --force-with-lease を保護ブランチ向けに）
  if printf '%s' "$push_segment" | grep -qE '(\-\-force([^-]|$)|[[:space:]]-[a-zA-Z]*f([[:space:]]|$)|--force-with-lease)'; then
    if ref_targets_protected "$push_segment" || is_protected "$current"; then
      deny "保護ブランチへの force-push は禁止です。feature ブランチで --force-with-lease を使ってください。"
    fi
  fi
  # 保護ブランチへの直接 push（force 問わず）
  if ref_targets_protected "$push_segment" || is_protected "$current"; then
    deny "保護ブランチ(main/master/develop)への直接 push は禁止です。feature ブランチで作業し PR を出してください。"
  fi
done <<< "$push_segments"

allow
