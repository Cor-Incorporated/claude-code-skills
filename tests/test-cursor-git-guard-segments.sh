#!/usr/bin/env bash
# Phase 18 T18-2: Cursor push rules only inspect the `git push` segment.
#
# 2026-09-03 改訂 — 環境依存の除去。
#
# 旧版は guard を**作業ツリーの現在ブランチ**の上で起動していた。`git-guard.sh`
# は `git rev-parse --abbrev-ref HEAD` で周囲のブランチを読むため、
# **測っている対象ではなく実行環境で結果が変わっていた。**
#
#   develop / main をチェックアウトした状態 → 4 件 red
#   feature ブランチ / detached HEAD        → 9 件 green
#
# その結果 CI は次のように割れていた（同一コミット・同一 job・同一コード）。
#
#   pull_request イベント: checkout@v4 は merge ref を detached HEAD で取る
#                          → `rev-parse --abbrev-ref HEAD` = "HEAD" = 非保護 → 緑
#   push イベント (develop): checkout@v4 は refs/heads/develop をブランチで取る
#                          → 同コマンドが "develop" を返す = 保護 → 赤
#
# 実測: PR run 33644668777 = "All hook tests passed" /
#       push run 33644918965 = "FAILED: tests/test-cursor-git-guard-segments.sh"。
# develop の CI はこれ 1 本だけで **2026-08-21 07:57 から約 12 日間赤**だった
# （run 32460906915 で同一の失敗を確認）。PR では緑なので誰にも見えなかった。
#
# 対処: fixture リポジトリを作り、**測るブランチを明示的に切り替えて**起動する。
# 周囲の状態は一切読ませない。各ブロックの先頭で「今どのブランチで測っているか」
# を出力するので、環境依存が再び入れば出力に現れる。
#
# 保護ブランチ上の期待値は本改訂で**新たに決めた**。根拠は下の
# 「保護ブランチ上での期待値の決め方」を読むこと。
set -uo pipefail
export AIDD_LEDGER_SOURCE=test

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/cursor/git-guard.sh"
SB=$(mktemp -d)
mkdir -p "$SB/.cursor/hooks"

# --- fixture: ブランチを制御できる使い捨てリポジトリ ---
# commit が 1 つ無いと `rev-parse --abbrev-ref HEAD` が unborn branch で失敗し、
# current が空になる（= 非保護扱い）。保護ブランチ側が測れなくなるので必ず作る。
# user.email/user.name は -c で渡す。CI のグローバル設定に依存させない。
FIX="$SB/fixture"
git init -q "$FIX"
git -C "$FIX" symbolic-ref HEAD refs/heads/develop
git -C "$FIX" -c user.email=test@example.invalid -c user.name=test \
  commit -q --allow-empty -m init
git -C "$FIX" branch feat/x

pass=0
fail=0
BRANCH=""

use_branch() {
  BRANCH="$1"
  git -C "$FIX" checkout -q "$BRANCH"
  local actual
  # `|| true` は握り潰しではない。直後の等値検査が fail-closed で、失敗時は
  # 空文字になって FATAL に落ちる。ここで exit しないと「切替できていないのに
  # 非保護扱いで全部緑」という、まさに今回直している形になる。
  actual=$(cd "$FIX" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ "$actual" != "$BRANCH" ]]; then
    printf 'FATAL: fixture のブランチ切替に失敗 (要求=%s 実際=%s)\n' "$BRANCH" "$actual"
    exit 1
  fi
  # 測定ブランチを必ず出力する。環境依存が再び入ったらここが手がかりになる。
  printf '\n=== 測定ブランチ: %s (%s) ===\n' "$BRANCH" \
    "$([[ "$BRANCH" == "develop" ]] && echo 保護 || echo 非保護)"
}

permission() {
  local command="$1" payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$command")
  # cwd を fixture にする。guard はここから current branch を読む。
  printf '%s' "$payload" \
    | (cd "$FIX" && env HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$HOOK" 2>/dev/null) \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permission", "missing"))'
}

check() {
  local name="$1" expected="$2" command="$3" actual
  actual=$(permission "$command")
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: [%s] %s expected=%s actual=%s\n' "$BRANCH" "$name" "$expected" "$actual"
    pass=$((pass + 1))
  else
    printf 'FAIL: [%s] %s expected=%s actual=%s command=%s\n' \
      "$BRANCH" "$name" "$expected" "$actual" "$command"
    fail=$((fail + 1))
  fi
}

# =============================================================================
# 保護ブランチ上での期待値の決め方（本改訂で新たに決めた部分）
# =============================================================================
# 旧版の 4 件の red は **単一の原因ではなかった**。2 つに分かれる。
#
# (A) `git push -u origin HEAD …` — develop 上で `HEAD` は develop に解決する。
#     **この push は実際に develop を押す。** deny が正しい。旧版の allow 期待
#     が、非保護ブランチ上であることを暗黙に仮定していただけである。
#     → 期待値を deny に直した。
#
# (B) `git push origin feat/x` — 明示 refspec が非保護ブランチを指しており、
#     develop の ref を触らない。current branch は結果に無関係。
#     **これは過剰ブロックであり、guard を直した。** 根拠 3 本:
#
#       1. 意味論: local feat/x → remote refs/heads/feat/x。develop は動かない
#       2. 同リポの Claude 側実装が既に正しい。hooks/protect-branches.sh は
#          current branch を「明示 ref が無いときのフォールバック」に限定して
#          いる（"No explicit protected ref: fall back to current branch"）。
#          cursor 側だけがこれを無条件に当てていた
#       3. tests/test-cross-tool-force-matrix.sh の GOOD 配列（4 強制点すべてが
#          allow すべき正常形）に `git push origin feat/x` と
#          `git push -u origin docs/y` が入っている。develop 上で実行すると
#          実測で `ClaudeCode=0 Cursor=2 Codex=0` の偽陽性が出ていた。
#          **リポジトリ自身が既に偽陽性と判定していた**
#
# 安全境界は緩めていない。(B) の修正は「push segment が明示的に非保護の宛先を
# 名指している」場合に限られる。暗黙 push（`git push` / `git push origin` /
# `HEAD`）は保護ブランチ上で deny のままであり、下の「暗黙 push」節で固定した。
# =============================================================================

# -----------------------------------------------------------------------------
use_branch feat/x
# -----------------------------------------------------------------------------
echo '--- safe push × unrelated protected-branch token (separator axis) ---'
check 'and separator' allow 'git push -u origin HEAD && gh pr create --base main'
check 'semicolon separator' allow 'git push -u origin HEAD; gh pr create --base main'
check 'or separator' allow 'git push -u origin HEAD || gh pr create --base main'

echo '--- destructive push remains denied in its own segment ---'
check 'mirror before PR' deny 'git push origin --mirror && gh pr create --base feat/x'
check 'direct main after safe command' deny 'printf ready; git push origin main'
check 'force refspec before PR' deny 'git push origin +HEAD:main || gh pr create --base feat/x'

echo '--- ordinary single commands ---'
check 'feature push' allow 'git push origin feat/x'
check 'direct protected push' deny 'git push origin develop'
check 'non-push' allow 'git status'

echo '--- 暗黙 push（非保護ブランチ上なので通る）---'
check 'bare push' allow 'git push'
check 'push origin (refspec なし)' allow 'git push origin'
check 'push HEAD 単体' allow 'git push -u origin HEAD'

# -----------------------------------------------------------------------------
use_branch develop
# -----------------------------------------------------------------------------
echo '--- (A) HEAD は develop に解決する → deny が正しい ---'
# 旧版はここを allow と期待していた。それが 12 日間の赤の本体である。
check 'and separator (HEAD=develop)' deny 'git push -u origin HEAD && gh pr create --base main'
check 'semicolon separator (HEAD=develop)' deny 'git push -u origin HEAD; gh pr create --base main'
check 'or separator (HEAD=develop)' deny 'git push -u origin HEAD || gh pr create --base main'

echo '--- 暗黙 push は保護ブランチ上で deny（guard 修正で緩めていないことの対照）---'
# この 4 件が red になったら、guard の修正が行き過ぎて保護を壊している。
check 'bare push' deny 'git push'
check 'push origin (refspec なし)' deny 'git push origin'
check 'push HEAD 単体' deny 'git push -u origin HEAD'
check 'force push (暗黙)' deny 'git push --force'

echo '--- 破壊形は保護ブランチ上でも当然 deny ---'
check 'mirror before PR' deny 'git push origin --mirror && gh pr create --base feat/x'
check 'direct main after safe command' deny 'printf ready; git push origin main'
check 'force refspec before PR' deny 'git push origin +HEAD:main || gh pr create --base feat/x'
check 'direct protected push' deny 'git push origin develop'

echo '--- (B) 明示的に非保護の宛先を名指す push は通す（過剰ブロックの修正）---'
# cross-tool-force-matrix.sh の GOOD 配列と一致させる。Claude Code と Codex は
# 元から通しており、Cursor だけが落としていた。
check 'feature push' allow 'git push origin feat/x'
check 'docs push (matrix GOOD と同一)' allow 'git push -u origin docs/y'
check 'refspec 形の feature push' allow 'git push origin HEAD:feat/x'

echo '--- 非 push は保護ブランチ上でも通る ---'
check 'non-push' allow 'git status'

printf '\n%s\n' "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
