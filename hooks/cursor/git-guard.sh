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

# 台帳の 1 行。deny 行の形式は変えない（集計スクリプトの互換）。
#
# 2026-09-05 (claude-code-skills#385): 従来は deny のときだけ書いていた。
# 実 cursor-agent に保護ブランチへの push を 3 回試行させて台帳が 414 → 414 のとき、
# 「push を試みなかった」と「試みたが allow された（= ガードが効いていない）」を
# **区別できなかった**。push/merge の判定に到達して allow したときも 1 行残す。
# 判定に到達しない素通り（ls 等）は既定では書かない（台帳を汚さない）。
# CURSOR_GIT_GUARD_TRACE=1 のときだけ素通りも decision:"invoked" で残す
# （実エージェントがシェルを 1 度でも実行したかを測る用途）。
ledger_row() {
  printf '{"ts":"%s","hook":"git-guard","decision":"%s","cmd_head":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$cmd" | head -c 120 | tr '"' "'")" \
    >> "$HOME/.cursor/hooks/guard-ledger.jsonl" 2>/dev/null || true
}

deny() {
  ledger_row deny
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
# allow "judged": push/merge の判定を通って allow した（常に台帳へ）
# allow        : 判定に到達しない素通り（TRACE 時のみ "invoked" として台帳へ）
allow() {
  if [[ "${1:-}" == "judged" ]]; then
    ledger_row allow
  elif [[ "${CURSOR_GIT_GUARD_TRACE:-0}" == "1" ]]; then
    ledger_row invoked
  fi
  printf '{"permission":"allow"}'
  exit 0
}

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

# push segment の**宛先**ブランチを返す。決められない（= 暗黙 push）なら空文字。
#
#   git push                    -> ""      refspec 無し。current を押す
#   git push origin             -> ""      同上
#   git push --force            -> ""      同上
#   git push origin HEAD        -> ""      HEAD は current に解決する = 暗黙
#   git push origin feat/x      -> feat/x
#   git push -u origin docs/y   -> docs/y
#   git push origin HEAD:feat/x -> feat/x  dst 側を採る
#   git push origin +main:main  -> main
#
# 空文字のときだけ current branch へ倒す。これは hooks/protect-branches.sh の
#   "No explicit protected ref: fall back to current branch (implicit push)"
# と同じ設計である。4 ツール横断で cursor 側だけがこの限定を持っていなかった。
push_destination() {
  printf '%s' "$1" | awk '
    {
      pi = 0
      for (i = 1; i <= NF; i++) if ($i == "push") { pi = i; break }
      if (pi == 0) { print ""; exit }
      n = 0
      for (i = pi + 1; i <= NF; i++) {
        t = $i
        if (substr(t, 1, 1) == "-") {
          # 値を取るフラグは次の語も飛ばす（飛ばさないと値を refspec と誤読する）
          if (t == "-o" || t == "--push-option" || t == "--repo" || t == "--receive-pack") i++
          continue
        }
        n++
        positional[n] = t
      }
      # positional[1] = remote, positional[2] = refspec
      if (n < 2) { print ""; exit }
      ref = positional[2]
      sub(/^\+/, "", ref)
      if (index(ref, ":") > 0) sub(/^[^:]*:/, "", ref)
      sub(/^refs\/heads\//, "", ref)
      if (ref == "HEAD") { print ""; exit }
      print ref
    }
  '
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
  #
  # 2026-09-03: current branch を **明示の宛先が無いときのフォールバックに限定**
  # した。従来は `|| is_protected "$current"` を無条件に当てていたため、
  # develop 上の `git push origin feat/x` を落としていた。この push は
  # refs/heads/feat/x しか触らず develop の ref を動かさないので過剰ブロックである。
  #
  # 実測の裏づけ: tests/test-cross-tool-force-matrix.sh の GOOD 配列
  # （4 強制点すべてが allow すべき正常形）を develop 上で回すと
  #   正常形 3 件中の偽陽性: ClaudeCode=0  Cursor=2  Codex=0
  # となり、Claude Code と Codex は通し **Cursor だけが落としていた**。
  # 「片方だけ変えない」対の、cursor 側が崩れていた側である。
  #
  # 緩めていないことの担保:
  #   - 明示的に保護 ref を名指す形は ref_targets_protected が先に落とす
  #     （`origin feat/x develop` の複数 refspec、`HEAD:refs/heads/main` を含む）
  #   - 暗黙 push（refspec 無し / `HEAD`）は従来どおり current で落とす
  #   - force 判定（上のブロック）は無条件のまま。触っていない
  # tests/test-cursor-git-guard-segments.sh が保護 / 非保護の両方で固定する。
  if ref_targets_protected "$push_segment"; then
    deny "保護ブランチ(main/master/develop)への直接 push は禁止です。feature ブランチで作業し PR を出してください。"
  fi
  if [[ -z "$(push_destination "$push_segment")" ]] && is_protected "$current"; then
    deny "保護ブランチ '${current}' からの暗黙 push は禁止です。押す先を明示するか、feature ブランチで作業してください。"
  fi
done <<< "$push_segments"

allow judged
