#!/bin/bash
# =============================================================================
# Protected Branch Guard Hook
# =============================================================================
# 4ツール横断の強制点の 1 つ。他: git-push-guard.sh /
# ~/.cursor/hooks/git-guard.sh / ~/.codex/rules/default.rules /
# ~/.config/opencode/opencode.jsonc permission
# 片方だけ変えない（tests/test-cross-tool-force-matrix.sh）
# =============================================================================
# Prevents deletion of protected branches (develop, main, master) via:
#   - gh pr merge --delete-branch (checks PR source branch)
#   - git branch -d/-D <protected>
#   - git push origin --delete <protected>
#   - git push origin :<protected>
#
# Fork-aware features (#191, #192):
#   - Force push detection: blocks to upstream, warns to fork remote
#   - Dynamic protected branches: adds upstream default branch
#   - Fork detection via: git remote get-url upstream
#
# Usage: PreToolUse hook in ~/.claude/settings.json
# Input: JSON on stdin with tool_input.command
# Exit codes:
#   0 = allow (outputs JSON unchanged)
#   2 = block (stderr message shown to user)
# =============================================================================

set -euo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"
_aidd_block() {
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "protect-branches" "block" "deny" "${cmd:-}" "protect-branches"
  fi
  exit 2
}
_aidd_ask() {
  local reason="$1"
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "protect-branches" "warn" "warn" "${cmd:-}" "foreign-pr-repo"
  fi
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}' \
    2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"foreign PR repository owner differs from origin"}}\n'
  exit 0
}

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

PROTECTED_BRANCHES="develop main master"

# --- Fork detection (#191) ---
is_fork_workflow() {
  git remote get-url upstream >/dev/null 2>&1
}

# --- Dynamic branch protection (#191) ---
extend_protected_branches() {
  if ! is_fork_workflow; then
    return
  fi
  local upstream_url upstream_repo upstream_default
  upstream_url=$(git remote get-url upstream 2>/dev/null || echo "")
  [ -z "$upstream_url" ] && return
  upstream_repo=$(echo "$upstream_url" \
    | sed -E 's#.*github\.com[:/]##;s/\.git$//')
  # Portable timeout: prefer timeout, fallback to gtimeout, then no timeout
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout 5"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout 5"
  fi
  upstream_default=$($timeout_cmd gh api "repos/${upstream_repo}" \
    --jq '.default_branch' 2>/dev/null || echo "")
  if [ -n "$upstream_default" ]; then
    if ! echo "$PROTECTED_BRANCHES" | grep -qw "$upstream_default"; then
      PROTECTED_BRANCHES="$PROTECTED_BRANCHES $upstream_default"
    fi
  fi
}

extend_protected_branches

# --- Force push detection (#192) ---
is_force_push() {
  local push_cmd="$1"
  if echo "$push_cmd" | grep -qE '(--(force|force-with-lease)\b|-f\b)'; then
    return 0
  fi
  if echo "$push_cmd" | grep -qE 'push\s+-[a-zA-Z]*f'; then
    return 0
  fi
  return 1
}

# mentions_protected_ref <cmd> <branch>: position-independent protected-branch
# detection (mirror of git-push-guard.sh). Catches force push hidden in process
# substitution `<(...)`, command chains, or redirects where token-position
# extraction fails.
mentions_protected_ref() {
  printf '%s' "$1" | grep -qE "(^|[^A-Za-z0-9._/-])(refs/heads/)?$2([^A-Za-z0-9._/-]|$)"
}

extract_push_remote() {
  local push_cmd="$1"
  # Strip 'git push', then remove all flags, take first positional arg
  echo "$push_cmd" | sed 's/git[[:space:]]*push[[:space:]]*//' \
    | sed 's/[[:space:]]*--[a-zA-Z-]*//g; s/[[:space:]]*-[a-zA-Z]//g' \
    | awk '{print $1}'
}

extract_push_branch() {
  local push_cmd="$1"
  # Strip 'git push', remove all --flag and -x options (including -o value pairs)
  local args
  args=$(echo "$push_cmd" | sed 's/git[[:space:]]*push[[:space:]]*//')
  # Remove --key=value flags
  args=$(echo "$args" | sed 's/[[:space:]]*--[a-zA-Z-]*=[^[:space:]]*//g')
  # Remove --key flags (--force-with-lease, --repo, etc)
  args=$(echo "$args" | sed 's/[[:space:]]*--[a-zA-Z-]*//g')
  # Remove -o <value> pairs (push option)
  args=$(echo "$args" | sed 's/[[:space:]]*-o[[:space:]][^[:space:]]*//g')
  # Remove remaining single-char flags (-f, -u, etc)
  args=$(echo "$args" | sed 's/[[:space:]]*-[a-zA-Z]//g')
  # Now: <remote> <refspec-or-branch>
  local branch
  branch=$(echo "$args" | awk '{print $2}')
  # Handle refspec: src:dst -> extract dst
  if [[ "$branch" == *:* ]]; then
    branch="${branch##*:}"
  fi
  # Strip refs/heads/ prefix
  branch="${branch#refs/heads/}"
  echo "$branch"
}

# --- 入力正規化（loop-break T1 follow-up・F1 18 ケース列挙で発見した 3 クラスの穴）---
# 実測（2026-08-11）: 18 破壊形のうち 8 形が通過していた。
#   (1) 引用形  `git push origin "--mirror"` / `'--mirror'`
#       → 空白アンカー `\s--` が引用符の直後にマッチせず素通り
#   (2) refspec force  `git push origin +main` / `+main:main` / `HEAD:+main`
#       → クラス丸ごと未被覆。`+<ref>` は --force と等価の標準記法
#   (3) git グローバルオプション前置  `git -c foo=bar push origin --mirror`
#       → `\bgit\s+push\b` が `git` と `push` の隣接を要求していた
# 対処: 引用符を除去した正規化文字列に対して照合し、push 検出はグローバル
# オプションを許容する。この 3 軸は F1 マトリクスで固定してある
# （tests/test-destructive-push-forms.sh — 破壊形 20 + 偽陽性 7 = 27 ケース）。
# cmd_norm / _GIT_PUSH_RE / Check 0a / Check 0a2 を触ったら必ず再実行すること。
# 修正前の版に対して 9 件 red になることを確認済み（2026-08-11）。
cmd_norm=$(printf '%s' "$cmd" | tr -d "\"'")

# --- Foreign repository PR target gate (Phase 15 T15-1) ---
# `--repo` is explicit user intent. When its owner differs from origin's owner,
# ask instead of block because legitimate OSS contributions are allowed after
# human confirmation. No --repo means gh's configured default and is out of
# scope here (OC-D8 owns that path).
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
      _aidd_ask "PR target owner '${target_owner}' differs from origin owner '${origin_owner}'. Confirm this cross-repository contribution."
    fi
  fi
fi

# `git [global-opts...] push` — `git -c k=v push` / `git --no-pager push` を含む
_GIT_PUSH_RE='(^|[^[:alnum:]_-])git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*push([^[:alnum:]_-]|$)'

# --- Check 0a: --all/--mirror guard (independent of --force flag) (#195) ---
# Reverted from R6 flag-position parser (loop-break T1): that parser missed the
# canonical argv order `git push origin --mirror` / `git push origin --all`.
# False positives on documentation text are accepted; broken protection is worse.
# --mirror and --all push ALL refs, implying forced updates even without --force
if echo "$cmd_norm" | grep -qE "$_GIT_PUSH_RE" && echo "$cmd_norm" | grep -qE '[[:space:]]--(all|mirror)([^[:alnum:]_-]|$)'; then
  echo "[BLOCK] --all/--mirror 付き push を検出。" >&2
  echo "  WHY: 全ブランチ(保護ブランチ含む)の履歴が上書き/削除されます。" >&2
  echo "  FIX: 個別のブランチを指定して push してください。" >&2
  _aidd_block
fi

# --- Check 0a2: refspec force `+<ref>` guard (loop-break T1 follow-up) ---
# `git push origin +main` は `--force` を伴わずに保護ブランチの履歴を上書きする。
# `+` は refspec の先頭にのみ意味を持つため、空白または `:` の直後に限定して
# 照合する（`git push origin feat/a+b` のようなブランチ名は誤検知しない）。
if echo "$cmd_norm" | grep -qE "$_GIT_PUSH_RE" && echo "$cmd_norm" | grep -qE '[[:space:]:]\+[A-Za-z0-9_./-]'; then
  echo "[BLOCK] refspec force (+<ref>) 付き push を検出。" >&2
  echo "  WHY: '+' 接頭辞は --force と等価で、保護ブランチの履歴を上書きします。" >&2
  echo "  FIX: '+' を外し、通常の push を行ってください。" >&2
  _aidd_block
fi

# --- Check 0b: Force push guard (fork-aware) (#192, #195, parser-gap fix) ---
if echo "$cmd_norm" | grep -qE "$_GIT_PUSH_RE" && is_force_push "$cmd_norm"; then
  # Position-independent protected-branch detection: a protected branch ref
  # appearing anywhere in a force-push command is caught, even when hidden in
  # process substitution `cat <(git push --force origin main)`, command chains
  # `echo x && git push --force origin main`, or redirects. The previous
  # token-position extraction assumed `git push` led the command and mis-read
  # the branch (e.g. `main)`), allowing the push through.
  matched_protected=""
  for pb in $PROTECTED_BRANCHES; do
    if mentions_protected_ref "$cmd" "$pb"; then
      matched_protected="$pb"
      break
    fi
  done

  if is_fork_workflow; then
    push_remote=$(extract_push_remote "$cmd")
    push_remote="${push_remote:-origin}"
    # Standard fork layout: origin=fork, upstream=parent.
    # Block force push to the parent (upstream remote or upstream token), and
    # block any protected branch ref as a safety net against obfuscated targets.
    if [ "$push_remote" = "upstream" ] \
       || printf '%s' "$cmd" | grep -qE '(^|[^A-Za-z0-9._/-])upstream([^A-Za-z0-9._/-]|$)' \
       || [ -n "$matched_protected" ]; then
      echo "[BLOCK] upstream (親リポジトリ) / 保護ブランチ への force push を検出。" >&2
      echo "  fork ワークフローでは upstream・保護ブランチへの force push は禁止です。" >&2
      echo "  WHY: 親リポジトリ/共有ブランチの履歴を書き換えると他の contributor に影響します。" >&2
      echo "  FIX: PR 経由でマージしてください。" >&2
      _aidd_block
    fi
    # origin = fork, allow with warning
    echo "[WARN] fork リモート '${push_remote}' への force push を検出。" >&2
    echo "  自分の fork への force push は許可しますが、注意してください。" >&2
  else
    # Non-fork: explicit protected branch ref anywhere -> block.
    if [ -n "$matched_protected" ]; then
      echo "[BLOCK] 保護ブランチ '${matched_protected}' への force push を検出。" >&2
      echo "  WHY: 共有ブランチの履歴書き換えは禁止です。" >&2
      echo "  FIX: feature ブランチで作業し、PR 経由でマージしてください。" >&2
      _aidd_block
    fi
    # No explicit protected ref: fall back to current branch (implicit push).
    target_branch=$(extract_push_branch "$cmd")
    if [ -z "$target_branch" ]; then
      target_branch=$(git branch --show-current 2>/dev/null || echo "")
    fi
    for branch in $PROTECTED_BRANCHES; do
      if [ "$target_branch" = "$branch" ]; then
        echo "[BLOCK] 保護ブランチ '${branch}' への force push を検出（暗黙的ブランチ）。" >&2
        echo "  WHY: 共有ブランチの履歴書き換えは禁止です。" >&2
        echo "  FIX: feature ブランチで作業し、PR 経由でマージしてください。" >&2
        _aidd_block
      fi
    done
  fi
fi

# --- Check 1: Direct branch deletion (git branch -d/-D) ---
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd" | grep -qE "git\s+branch\s+-[dD]\s+.*\b${branch}\b"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted locally." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        _aidd_block
    fi
done

# --- Check 2: Remote branch deletion (git push --delete) ---
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd" | grep -qE "push\s+.*--delete\s+.*\b${branch}\b"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted from remote." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        _aidd_block
    fi
done

# --- Check 3: Remote branch deletion (git push origin :branch) ---
# Also :refs/heads/<branch> (Phase 3 T3-1 — bare :main was covered; full ref was not).
for branch in $PROTECTED_BRANCHES; do
    if echo "$cmd_norm" | grep -qE "push[[:space:]]+[^[:space:]]+[[:space:]]+:(refs/heads/)?${branch}([^A-Za-z0-9._/-]|$)"; then
        echo "[Hook] BLOCKED: Protected branch '${branch}' cannot be deleted from remote." >&2
        echo "[Hook] develop/main/master branches are tied to CI/CD and must NEVER be deleted." >&2
        _aidd_block
    fi
done

# --- Check 3b: Direct push to protected (non-force) including refs/heads/ forms ---
# Primary owner is git-push-guard.sh; this is coverage repair so protect-branches
# alone also blocks HEAD:refs/heads/main and refs/heads/main (Cursor/Codex parity).
# False positives on feat/* and docs that merely mention main are excluded by
# requiring a git push match + destination token equality (not bare substring).
if echo "$cmd_norm" | grep -qE "$_GIT_PUSH_RE"; then
  push_target=$(echo "$cmd_norm" | grep -oE "push[[:space:]]+[^|;&)<>]*" | head -1 \
    | sed 's/^push[[:space:]]*//' | sed -E 's/[[:space:]]+-(u|f|q|-force|-force-with-lease|--set-upstream|--quiet)([^[:space:]]*)?//g' | xargs)
  refspec=$(echo "$push_target" | awk '{print $NF}')
  for branch in $PROTECTED_BRANCHES; do
    if [ "$refspec" = "$branch" ] \
       || [ "$refspec" = "refs/heads/${branch}" ] \
       || echo "$refspec" | grep -qE ":(refs/heads/)?${branch}$"; then
      echo "[BLOCK] 保護ブランチ '${branch}' への直接 push を検出。" >&2
      echo "  WHY: 共有ブランチへの直接 push は禁止です（refs/heads/ 表記含む）。" >&2
      echo "  FIX: feature ブランチで作業し、PR 経由でマージしてください。" >&2
      _aidd_block
    fi
  done
fi

# --- Check 4: gh pr merge --delete-branch (most dangerous!) ---
if echo "$cmd" | grep -qE 'gh\s+pr\s+merge.*--delete-branch'; then
    PR_CHECKED=false

    # Extract PR number
    PR_NUM=$(echo "$cmd" | grep -oE 'merge\s+[0-9]+' | grep -oE '[0-9]+' || echo "")

    if [ -n "$PR_NUM" ]; then
        # Query the PR's source (head) branch
        HEAD_BRANCH=$(gh pr view "$PR_NUM" --json headRefName -q '.headRefName' 2>/dev/null || echo "")

        if [ -n "$HEAD_BRANCH" ]; then
            PR_CHECKED=true
            for branch in $PROTECTED_BRANCHES; do
                if [ "$HEAD_BRANCH" = "$branch" ]; then
                    echo "[Hook] BLOCKED: PR #${PR_NUM} source branch is '${branch}' (protected)." >&2
                    echo "[Hook] --delete-branch would delete '${branch}', which is tied to CI/CD." >&2
                    echo "[Hook] Remove --delete-branch and run: gh pr merge ${PR_NUM} --merge" >&2
                    _aidd_block
                fi
            done
            # PR source branch is NOT protected - allow
        fi
    fi

    # Fallback: if we couldn't determine the PR's source branch, check current branch
    if [ "$PR_CHECKED" = "false" ]; then
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
        for branch in $PROTECTED_BRANCHES; do
            if [ "$CURRENT_BRANCH" = "$branch" ]; then
                echo "[Hook] BLOCKED: Cannot determine PR source branch, and current branch '${branch}' is protected." >&2
                echo "[Hook] --delete-branch could delete a protected branch." >&2
                echo "[Hook] Remove --delete-branch flag and retry." >&2
                _aidd_block
            fi
        done
    fi
fi

# All checks passed - allow the command
exit 0
