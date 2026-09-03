#!/bin/bash
# git-push-guard.sh — PreToolUse hook for git push (minimal safety net, ADR-006)
# Blocks: force-push to protected branches, direct push to protected branches.
set -euo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"
_aidd_block() {
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "git-push-guard" "block" "deny" "${cmd:-${cmd_norm:-}}" "protected-push"
  fi
  exit 2
}

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# --- Resolve git context dir: honor `cd <dir> && ...` and `git -C <dir>` ---
# The hook process cwd is the SESSION cwd, not the repo the command targets.
# Without this, the implicit-branch force-push check (git rev-parse HEAD) and
# the pre-push lint checks (rev-parse --show-toplevel) evaluate whatever repo
# the session happens to sit in — blocking pushes to repo B because repo A
# has lint errors, or misreading the current branch entirely.
ctx_dirs=$(CMD="$cmd" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
q1, q2 = chr(34), chr(39)
pat_val = r'((?:%s[^%s]+%s)|(?:%s[^%s]+%s)|(?:[^\s;&|]+))' % (q1, q1, q1, q2, q2, q2)
def _resolve(m):
    if not m:
        return ""
    d = os.path.expanduser(os.path.expandvars(m.group(1).strip(q1 + q2)))
    return d if d and os.path.isdir(d) else ""

# `git -C <dir>` wins over a leading `cd <dir> &&` (git resolves -C itself),
# but only when its value is a real directory — a `git -C` appearing inside a
# quoted string (e.g. an issue title) must not shadow a valid leading cd.
#
# Resolve -C per PUSHING invocation, not once for the whole command. Taking the
# first `git -C` anywhere mismatched the push target whenever an earlier
# invocation named a different repo: `git -C A status && git -C B push --force`
# read repo A's HEAD while repo B was the one actually pushed, so a force push
# to a protected branch fell through (rc 0) and a legitimate feature-branch one
# was blocked (rc 2). Every pushing segment is emitted, and the implicit-branch
# check below blocks if ANY of them sits on a protected branch — a second push
# must not hide behind a benign first one. Segment split matches
# hooks/cursor/git-guard.sh, which already scoped its push rules this way.
# (Issue #263)
lead_cd = _resolve(re.match(r'^\s*cd\s+' + pat_val + r'\s*(?:&&|;)', cmd))
seen, out = set(), []
for seg in re.split(r'&&|\|\||[;\n|]', cmd):
    if not re.search(r'\bgit\b.*\bpush\b', seg):
        continue
    d = _resolve(re.search(r'git\s+-C\s+' + pat_val, seg)) or lead_cd
    if d not in seen:
        seen.add(d)
        out.append(d)
print("\n".join(out) if out else lead_cd)
PY
)

# Current branch of every pushing invocation's repo (one per line).
# An empty ctx dir means the session cwd, which is what plain `git` reads.
ctx_branches() {
  local d
  while IFS= read -r d || [[ -n "$d" ]]; do
    if [[ -n "$d" ]]; then
      git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || true
    else
      git rev-parse --abbrev-ref HEAD 2>/dev/null || true
    fi
  done <<< "$ctx_dirs"
}

# cmd_norm: collapse git global options (-C <dir>, -c <k=v>, --no-pager) so the
# push/commit pattern matches below cannot be dodged with `git -C <repo> push`
# (fail-open bypass). Quote-aware: -C "/path with spaces" collapses too.
# ctx_dirs above still reads the ORIGINAL command.
cmd_norm=$(CMD="$cmd" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
q1, q2 = chr(34), chr(39)
val = r'(?:%s[^%s]*%s|%s[^%s]*%s|[^\s;&|]+)' % (q1, q1, q1, q2, q2, q2)
opt = r'(?:\s+-C\s+' + val + r'|\s+-c\s+' + val + r'|\s+--no-pager)'
print(re.sub(r'git' + opt + r'+(\s+)', r'git\g<1>', cmd), end="")
PY
)

# mentions_protected_ref <cmd> <branch>
# Returns 0 if <branch> appears as a push ref token anywhere in <cmd>, tolerant
# of process substitution `<(...)`, command chains, redirects and refspec forms
# (origin main / :main / refs/heads/main). Position-independent so a force push
# wrapped as `cat <(git push --force origin main)` can no longer hide the
# protected branch from extraction (parser-gap fix).
mentions_protected_ref() {
  printf '%s' "$1" | grep -qE "(^|[^A-Za-z0-9._/-])(refs/heads/)?$2([^A-Za-z0-9._/-]|$)"
}

has_explicit_push_ref() {
  # Detect "git push <remote> <ref>" even when wrapped in a chain or process
  # substitution. If a ref is explicit, current-branch fallback would be a false
  # positive when the hook itself runs from develop/main.
  local segment token after_push non_option_count normalized
  normalized=$(printf '%s' "$1" | tr '<>();|&' '\n')
  while IFS= read -r segment || [[ -n "$segment" ]]; do
    [[ "$segment" == *"git push"* ]] || continue
    after_push=false
    non_option_count=0
    for token in $segment; do
      if [[ "$after_push" != true ]]; then
        [[ "$token" == "push" ]] && after_push=true
        continue
      fi
      [[ "$token" == -* ]] && continue
      non_option_count=$((non_option_count + 1))
    done
    [[ "$non_option_count" -ge 2 ]] && return 0
  done <<< "$normalized"
  return 1
}

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

# --- 0. Early exit: only run on git push commands (Issue #150) ---
# Without this guard, black/ruff checks in section 3 block ALL Bash commands,
# creating an unrecoverable deadlock where even `black .` is blocked.
if ! echo "$cmd_norm" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

# --- 1. Force push to shared branches check (Issue #17) ---
# Block --force / --force-with-lease to develop/main/master
# Feature branches are allowed (user's own branch history cleanup is legitimate)
if echo "$cmd_norm" | grep -qE 'git\s+push\b.*(--(force|force-with-lease)\b|-f\b)' || \
   echo "$cmd_norm" | grep -qE 'git\s+push\s+-[a-zA-Z]*f'; then
    # Check explicit branch names in the command
    for branch in develop main master; do
        if mentions_protected_ref "$cmd_norm" "$branch"; then
            cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出

理由: force push は履歴を書き換えます。
  - 他のエンジニアの作業ベースが壊れる可能性
  - レビュー済みコミット履歴が失われる可能性
  - --force-with-lease も --force と同等に扱います

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #17 — AI からの force push はブロック、ユーザー手動実行に限定
ERRMSG
            _aidd_block
        fi
    done

    # Fallback: if no explicit push ref in command, check current branch
    # Catches: git push --force, git push --force origin (implicit branch)
    if ! has_explicit_push_ref "$cmd_norm"; then
      while IFS= read -r current_branch || [[ -n "$current_branch" ]]; do
        for branch in develop main master; do
            if [[ "$current_branch" == "$branch" ]]; then
                cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出（暗黙的ブランチ）

現在のブランチ '${branch}' は共有ブランチです。
コマンドにブランチ名が明示されていなくても、force push はブロックされます。

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #28 — 差分有無にかかわらず共有ブランチへの force push をブロック
ERRMSG
                _aidd_block
            fi
        done
      done < <(ctx_branches)
    fi
fi

# --- 2. Protected branch direct push check ---
# Destination is protected if refspec is bare branch, refs/heads/<branch>,
# or *:<branch> / *:refs/heads/<branch> (Phase 3 T3-1 coverage repair:
# HEAD:refs/heads/main and refs/heads/main previously slipped through
# because only ":${branch}$" / exact "${branch}" were matched).
_is_protected_push_dest() {
  local refspec="$1" branch="$2"
  [ "$refspec" = "$branch" ] && return 0
  [ "$refspec" = "refs/heads/${branch}" ] && return 0
  echo "$refspec" | grep -qE ":(refs/heads/)?${branch}$" && return 0
  return 1
}
for branch in develop main master; do
    # Exclude only pure delete refspecs (`--delete` or a bare leading `:branch`
    # with no source ref before the colon) — `HEAD:branch` / `feat:branch` are
    # real pushes to the protected branch and must still be caught below.
    # Also match refs/heads/<branch> (word-boundary alone is insufficient for
    # the dest equality check below; still used as a cheap prefilter).
    if echo "$cmd_norm" | grep -qE "git\s+push\s+.*(refs/heads/)?${branch}([^A-Za-z0-9._-]|$)" && \
       ! echo "$cmd_norm" | grep -qE "(--delete|(^|[[:space:]]):(refs/heads/)?${branch}\b)"; then
        push_target=$(echo "$cmd_norm" | grep -oE "push\s+[^|;&)<>]*" | sed 's/push\s*//' | sed 's/\s*-[a-zA-Z-]*//g' | xargs)
        refspec=$(echo "$push_target" | awk '{print $NF}')
        if _is_protected_push_dest "$refspec" "$branch"; then
            echo "[BLOCKED] Direct push to '${branch}'. Use PR instead." >&2
            echo "  git push -u origin feat/xxx && gh pr create --base develop" >&2
            _aidd_block
        fi
    fi
done

exit 0
