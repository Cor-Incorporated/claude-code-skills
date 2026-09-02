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
  # Optional rule tag. Without it every block is filed under one name, so the
  # ledger cannot say WHICH rule fired — and a rule with a high false-positive
  # rate becomes indistinguishable from one that is working. Existing call sites
  # pass nothing and keep the previous value.
  local rule="${1:-protect-branches}"
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "protect-branches" "block" "deny" "${cmd:-}" "$rule"
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
#
# 2026-09-02 の修正まで、この検査は 2 つの述語をコマンド文字列**全体**に対して
# 独立に当てていた:
#
#   grep -qE "$_GIT_PUSH_RE"  &&  grep -qE '[[:space:]:]\+[A-Za-z0-9_./-]'
#
# 両者が文字列の別の場所にあるだけで一致するため、**コミットメッセージが
# push ガードの話をしているだけで block した。** 同日 5 回発火し、運用者は
# `git commit -F <file>` で迂回した。参照: aidd-governance#100
#
# 本規則は偽陽性と偽陰性のコストが等しくない。
#   偽陽性 = コミットが 1 回止まる。`-F` に逃げれば回復する
#   偽陰性 = 保護ブランチの履歴が書き換わる。取り返しがつかない
# harness-spec は本 hook を tail-risk 型に分類している。したがって
# **既定は block（網）** とし、データ文脈だと積極的に同定できたセグメントだけを
# 除外する。除外できるのは次の 2 つだけである。
#
#   1. git の非 push サブコマンド（commit / log / show ...）— 引数は本文
#   2. 引数をデータとして扱うコマンド（grep / echo / cat / head / tail）
#
# **インタプリタを列挙しない。** 除外されなかったセグメントは、先頭が何であれ
# 中身を見る。`python3 -c` / `perl -e` / `node -e` / `ruby -e` / 未知のものも、
# 中に git push と `+<ref>` が並んでいれば同じ経路で網にかかる。
# 列挙は必ず漏れる。有限で短いのはデータ文脈の側だけである。
#
# 2026-09-02 の修正で 2 度退行させた。記録として残す。
#   第 1 版: 「push だと断定できたときだけ block」に倒し、群化形 7 種中 6 種を
#            素通しにした（`( git push ... )` のように括弧の後に空白がある形）。
#            括弧を剥がした残りが空文字トークンになり、それを飛ばしていなかった。
#   第 2 版: 網は戻したが、`hasgit` をトークン等価で見ていたため
#            `os.system(git push origin +main)` の `git` を拾えず、
#            インタプリタ経由 6 種を素通しにした。
#   いずれも「宣言では網、実装では素通し」であり、本リポが問題にしている
#   宣言↔実体の乖離そのものだった。
# heredoc の本文は、**それを食うコマンドがデータ文脈のときだけ**落とす。
#   cat <<EOF > note.md   → 本文はファイルへ書かれる。データである
#   python3 - <<PY        → 本文はインタプリタが実行する。コードである
# 無条件に落とすと後者が素通りする（第 2 版の欠陥の 1 つ）。
#
# Check 0a2 (#346) と Check 4 (#358) が共有する。#358 は「#346 が git push に
# 対して解いた位置判定が gh pr merge の述語には適用されていなかった」欠陥
# だった。同じ抽出を 2 度書くと、次も片方にだけ直しが入る。
strip_dataonly_heredoc_bodies() {
  printf '%s' "$1" | awk '
    function is_dataonly(t) {
      return (t == "grep" || t == "egrep" || t == "fgrep" || t == "rg" || t == "ag" ||
              t == "echo" || t == "printf" || t == "cat" || t == "tee" ||
              t == "head" || t == "tail")
    }
    BEGIN { delim = "" }
    {
      if (delim != "") {
        line = $0; sub(/^[ \t]+/, "", line)
        if (line == delim) delim = ""
        next
      }
      if (match($0, /<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
        # この行の最初のコマンド語を見る
        cw = ""
        for (i = 1; i <= NF; i++) {
          t = $i; gsub(/^[^A-Za-z0-9_]+/, "", t)
          if (t == "" || substr(t, 1, 1) == "-") continue
          cw = t; break
        }
        if (is_dataonly(cw)) {
          d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); delim = d
        }
      }
      print
    }
  '
}

has_refspec_force() {
  local body_stripped
  body_stripped="$(strip_dataonly_heredoc_bodies "$1")"

  # 区切りは `;` `|` `&` のみ。括弧では分割しない — 分割すると
  # `fix(#195): git push ... +195` が `: git push ... +195` という偽セグメントを
  # 生んで再び誤検知する（実測）。
  # shellcheck disable=SC2020 # 3 個の区切り文字を全て改行へ写す。重複は意図的で、
  # SET2 を 1 文字に縮めると tr 実装ごとの補完規則に依存してしまう。
  printf '%s' "$body_stripped" | tr ';|&' '\n\n\n' | awk '
    function takes_value(t) { return (t == "-c" || t == "--config" || t == "-C") }
    # 引数を「コマンドとして実行しうる」もの。読み飛ばして先の語を見に行く。
    # ここに無いインタプリタも、下の既定の網が拾う。列挙は網の前提ではない。
    function is_runner(t) {
      return (t == "env" || t == "sudo" || t == "doas" || t == "nohup" ||
              t == "time" || t == "timeout" || t == "stdbuf" || t == "nice" ||
              t == "ionice" || t == "setsid" || t == "command" || t == "exec" ||
              t == "xargs" || t == "eval" ||
              t == "bash" || t == "sh" || t == "zsh" || t == "dash" || t == "ksh" ||
              t ~ /^[A-Za-z_][A-Za-z0-9_]*=/)
    }
    # 引数を「データとして扱う」もの。ここに現れる `+` はコマンドではない。
    # 実行しうるもの（python -c / perl -e / node -e ...）は**入れない**。
    function is_dataonly(t) {
      return (t == "grep" || t == "egrep" || t == "fgrep" || t == "rg" || t == "ag" ||
              t == "echo" || t == "printf" || t == "cat" || t == "tee" ||
              t == "head" || t == "tail")
    }
    function strip_punct(t) { gsub(/^[^A-Za-z0-9_]+/, "", t); return t }
    {
      if (NF == 0) next

      # --- stage 1: データ文脈だと同定できたセグメントだけを除外する ---
      cw = ""; ci = 0
      for (i = 1; i <= NF; i++) {
        t = strip_punct($i)
        if (t == "") continue
        if (is_runner(t)) continue
        if (substr(t, 1, 1) == "-") continue
        cw = t; ci = i; break
      }
      if (ci > 0) {
        if (cw == "git") {
          subcmd = ""
          for (i = ci + 1; i <= NF; i++) {
            if (substr($i, 1, 1) == "-") { if (takes_value($i)) i++; continue }
            subcmd = $i; break
          }
          if (subcmd != "" && subcmd != "push") next
        } else if (is_dataonly(cw)) {
          next
        }
      }

      # --- stage 2 (既定の網): セグメント先頭が何であれ中身を見る ---
      # 区切り記号を空白へ潰してから再トークン化する。トークン等価だけで見ると
      # `os.system(git` の `git` を拾えず、インタプリタ経由が素通りする。
      # ref に意味のある文字（英数 _ . : / + -）だけを残す。
      s2 = $0
      gsub(/[^A-Za-z0-9_.:\/+-]/, " ", s2)
      n2 = split(s2, a2, /[ \t]+/)
      pi = 0
      for (i = 1; i <= n2; i++) if (a2[i] == "push") { pi = i; break }
      if (pi == 0) next
      hasgit = 0
      for (i = 1; i < pi; i++) if (a2[i] == "git") hasgit = 1
      if (hasgit == 0) next
      for (i = pi + 1; i <= n2; i++) {
        # `+main` / `+main:main`（先頭）と `HEAD:+main`（dst 側）の両形
        if (substr(a2[i], 1, 1) == "+" || index(a2[i], ":+") > 0) { print "FORCE"; exit }
      }
    }
  ' | grep -q FORCE
}

if has_refspec_force "$cmd_norm"; then
  echo "[BLOCK] refspec force (+<ref>) 付き push を検出。" >&2
  echo "  WHY: '+' 接頭辞は --force と等価で、保護ブランチの履歴を上書きします。" >&2
  echo "  FIX: '+' を外し、通常の push を行ってください。" >&2
  _aidd_block "refspec-force"
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
# 旧実装は 1 本の正規表現だった:
#
#   echo "$cmd" | grep -qE 'gh\s+pr\s+merge.*--delete-branch'
#
# これは 2 つの区別ができない（issue #358・同型欠陥 14 件目）。
#
#   (1) 値   `--delete-branch=false` は **削除しない** 指定である。それを
#            `--delete-branch` の前方一致で「削除しうる」と読んで block した。
#   (2) 位置 heredoc 本文・コミットメッセージに語が現れるだけで block した。
#            `cat > f.md <<EOF` はブランチを削除しない。ガードは
#            「フラグについて書くこと」と「フラグを使うこと」を混同していた。
#
# 修正前の実測（2026-09-02、現在ブランチ main の probe リポジトリ）:
#   gh pr merge 42 --merge --delete-branch        rc=2  block   期待どおり
#   gh pr merge 42 --merge --delete-branch=true   rc=2  block   期待どおり
#   gh pr merge 42 --merge --delete-branch=false  rc=2  block   ← 誤検知
#   gh pr merge 42 --merge -d                     rc=0  allow   ← 見逃し
#   gh pr merge 42 -dm                            rc=0  allow   ← 見逃し
#   cat > f.md <<EOF …(本文に語)… EOF             rc=2  block   ← 誤検知
#   git commit -m 'docs: gh pr merge … の注意'    rc=2  block   ← 誤検知
#
# **否定側の誤検知と肯定側の見逃しが同居していた。** 短縮形 `-d` を一度も
# 見ていないことが実測で確定したので、緩めるだけの修正では足りない。
#
# 値の意味は gh 2.98.0 で実測した（記憶で書かない）:
#   `--delete-branch=notabool` → invalid argument … strconv.ParseBool
#   `-d=notabool`              → 同じ ParseBool エラー
#       ⇒ 長形・短縮形とも `=value` は ParseBool で解釈される
#   `--delete-branch false`    → accepts at most 1 arg(s), received 2
#       ⇒ 空白区切りは値にならない。フラグは true。**block のまま**
#   ParseBool の偽側は 0 / f / F / FALSE / false / False の 6 語だけ
#
# 位置判定は #346 が has_refspec_force で確立した形を再利用する（新規に
# 書き起こさない）。既定は網（本 hook は tail-risk 型）で、データ文脈だと
# **積極的に同定できた**セグメントだけを除外する。
has_active_delete_branch() {
  local prepared
  # (1) データ文脈が食う heredoc 本文を落とす（#346 と同じ抽出を共有）
  prepared="$(strip_dataonly_heredoc_bodies "$1")"
  # (2) 行継続 `\<改行>` を畳む。畳まないと
  #       gh pr merge 42 --merge \
  #         --delete-branch
  #     が別セグメントに割れて見逃す。旧実装も grep が行単位なので同じ穴が
  #     あった。ここは緩める方向ではなく、見逃しを 1 つ塞ぐ方向の変更である。
  #     sed の `:a;N;$!ba` は使わない。BSD sed は最終行で N に当たると
  #     パターン空間を捨てるため、**1 行入力が丸ごと空になる**（macOS 実測）。
  #     空になれば述語は常に偽 = ガードが全面 fail-open する。bash 置換で行う。
  local _bs_nl=$'\\\n'
  prepared="${prepared//"$_bs_nl"/}"
  # (3) `$(` はコマンド置換の開始なので区切りにする。切らないと
  #     `git commit -m $(gh pr merge 1 --delete-branch)` が git セグメントとして
  #     除外され見逃す。
  #     裸の `(` では切らない — `fix(#195):` が偽セグメントを生んで #346 が
  #     踏んだ誤検知に戻る。バッククォートでも切らない — markdown のコード
  #     スパンと区別できず、言及を再び block してしまう（本 issue の 2 件目と
  #     同じ形）。この 2 つを切らないことは意図であって漏れではない。
  prepared="${prepared//'$('/;}"

  # `… | bash` の形はデータ文脈の除外を丸ごと無効にし、純粋な網に落とす。
  # 無効にしないと `echo "gh pr merge 1 --delete-branch" | bash` が echo
  # セグメントとして除外される。この入力は **修正前は block していた**（旧正規
  # 表現に一致するため）ので、素通しにすると見逃しの純増になる。実測:
  #   長形  echo "… --delete-branch" | bash  修正前 rc=2 → 修正後 rc=2（維持）
  #   短縮形 echo "… -d" | bash              修正前 rc=0 → 修正後 rc=2（新規に塞ぐ）
  # 誤検知を減らす修正で見逃しを増やしてはならない（issue #358 の安全境界）。
  local netonly=0
  if printf '%s' "$prepared" \
     | grep -qE '[|][[:space:]]*(bash|sh|zsh|ksh|dash|xargs)([^A-Za-z0-9_-]|$)'; then
    netonly=1
  fi

  # shellcheck disable=SC2020 # 3 個の区切り文字を全て改行へ写す（#346 と同形）
  printf '%s' "$prepared" | tr ';|&' '\n\n\n' | awk -v netonly="$netonly" '
    # strconv.ParseBool の偽側。これ以外の値は gh 自身がエラーにするので、
    # 判断できない値は「削除しうる」側に倒す。
    function is_false_val(v) {
      return (v == "0" || v == "f" || v == "F" ||
              v == "FALSE" || v == "false" || v == "False")
    }
    # トークンが「ブランチを削除する」指定か。
    # `=` の値は **直前の 1 文字** に束縛される（pflag 実測）:
    #   -dm=false → -d は true（値は m に効く）  … 削除する
    #   -md=false → 値は d に効く                … 削除しない
    # 値を取る短縮形（gh pr merge: -A -b -F -t）に当たったら、以降はその値。
    function delete_active(t,   eq, val, letters, n, i, c) {
      if (substr(t, 1, 2) == "--") {
        eq = index(t, "=")
        if (eq == 0) return (t == "--delete-branch")
        if (substr(t, 1, eq - 1) != "--delete-branch") return 0
        return (is_false_val(substr(t, eq + 1)) ? 0 : 1)
      }
      if (substr(t, 1, 1) != "-" || length(t) < 2) return 0
      eq = index(t, "=")
      if (eq > 0) { letters = substr(t, 2, eq - 2); val = substr(t, eq + 1) }
      else        { letters = substr(t, 2);         val = "" }
      n = length(letters)
      for (i = 1; i <= n; i++) {
        c = substr(letters, i, 1)
        if (c == "d") {
          if (eq > 0 && i == n) return (is_false_val(val) ? 0 : 1)
          return 1
        }
        if (c == "A" || c == "b" || c == "F" || c == "t") return 0
      }
      return 0
    }
    function is_runner(t) {
      return (t == "env" || t == "sudo" || t == "doas" || t == "nohup" ||
              t == "time" || t == "timeout" || t == "stdbuf" || t == "nice" ||
              t == "ionice" || t == "setsid" || t == "command" || t == "exec" ||
              t == "xargs" || t == "eval" ||
              t == "bash" || t == "sh" || t == "zsh" || t == "dash" || t == "ksh" ||
              t ~ /^[A-Za-z_][A-Za-z0-9_]*=/)
    }
    function is_dataonly(t) {
      return (t == "grep" || t == "egrep" || t == "fgrep" || t == "rg" || t == "ag" ||
              t == "echo" || t == "printf" || t == "cat" || t == "tee" ||
              t == "head" || t == "tail")
    }
    function strip_punct(t) { gsub(/^[^A-Za-z0-9_]+/, "", t); return t }
    {
      if (NF == 0) next

      # --- stage 1: データ文脈だと同定できたセグメントだけを除外する ---
      if (netonly == 0) {
        cw = ""; ci = 0
        for (i = 1; i <= NF; i++) {
          t = strip_punct($i)
          if (t == "") continue
          if (is_runner(t)) continue
          if (substr(t, 1, 1) == "-") continue
          cw = t; ci = i; break
        }
        if (ci > 0) {
          # git は gh を起動しない。コミットメッセージ本文はここで落ちる。
          if (cw == "git") next
          if (is_dataonly(cw)) next
        }
      }

      # --- stage 2 (既定の網): セグメント先頭が何であれ中身を見る ---
      # 区切り記号を空白へ潰してから再トークン化する。トークン等価だけで見ると
      # `os.system(gh pr merge 1 -d)` の `gh` を拾えない（#346 の第 2 版と同じ穴）。
      # フラグの形を保つため `=` `-` は残す。
      s2 = $0
      gsub(/[^A-Za-z0-9_.:\/=+-]/, " ", s2)
      n2 = split(s2, a2, /[ \t]+/)
      gi = 0
      for (i = 1; i <= n2; i++) {
        if (a2[i] == "gh" || a2[i] ~ /\/gh$/) { gi = i; break }
      }
      if (gi == 0) next
      pi = 0; mi = 0
      for (i = gi + 1; i <= n2; i++) if (a2[i] == "pr")    { pi = i; break }
      if (pi == 0) next
      for (i = pi + 1; i <= n2; i++) if (a2[i] == "merge") { mi = i; break }
      if (mi == 0) next
      for (i = gi + 1; i <= n2; i++) {
        if (delete_active(a2[i])) { print "ACTIVE"; exit }
      }
    }
  ' | grep -q ACTIVE
}

if has_active_delete_branch "$cmd_norm"; then
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
                    # 規則名で台帳に積む。無いと Check 0a2 などと同じ名前で
                    # 混ざり、「この規則の誤検知率」が測れない（#346 が
                    # _aidd_block にタグ引数を足したのはそのため）。
                    _aidd_block "delete-branch"
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
                echo "[Hook] NOTE: --delete-branch=false は削除しない指定なので通ります。" >&2
                _aidd_block "delete-branch"
            fi
        done
    fi
fi

# All checks passed - allow the command
exit 0
