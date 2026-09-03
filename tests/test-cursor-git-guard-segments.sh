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

# =============================================================================
# 文脈対照表（2026-09-03 改訂で本形式にした）
# =============================================================================
# ブランチごとに節を分けて `check` を並べる書き方だと、**なぜ deny なのかが
# 「たまたま develop 上で走ったから」に見える。** 期待値を deny に直しただけの
# テストは、次に checkout 方式が変わったときまた同じことを起こす。
#
# そこで、**1 コマンドにつき保護／非保護の両方の期待値を 1 行で宣言する**形に
# した。`ctx_case` は同じコマンドを両ブランチで走らせ、期待値が文脈でどう変わる
# かと**その理由**を表に出す。理由欄が書けないケースは、期待値の根拠が無い。
#
#   同じ期待値の行  → current branch に依存しない判定である
#   異なる期待値の行 → current branch に依存する判定である。理由欄がその説明
# =============================================================================

ctx_rows=()

# ctx_case <name> <expect_on_feat/x> <expect_on_develop> <cmd> <why>
ctx_case() {
  local name="$1" exp_feat="$2" exp_dev="$3" cmd="$4" why="$5"
  local got_feat got_dev

  git -C "$FIX" checkout -q feat/x
  BRANCH="feat/x"; got_feat=$(permission "$cmd")
  git -C "$FIX" checkout -q develop
  BRANCH="develop"; got_dev=$(permission "$cmd")

  local mark=" "
  if [[ "$got_feat" == "$exp_feat" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); mark="X"
    printf 'FAIL: [feat/x] %s expected=%s actual=%s command=%s\n' "$name" "$exp_feat" "$got_feat" "$cmd"
  fi
  if [[ "$got_dev" == "$exp_dev" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); mark="X"
    printf 'FAIL: [develop] %s expected=%s actual=%s command=%s\n' "$name" "$exp_dev" "$got_dev" "$cmd"
  fi

  local depends="同一"
  [[ "$exp_feat" != "$exp_dev" ]] && depends="**文脈依存**"
  # 区切りは ASCII Unit Separator。`|` を使うと `git push … || gh pr create …` の
  # コマンド自身が区切りに化けて、表の行が壊れる（実測で 2 行崩れた）。
  # 検体に `||` が含まれるスイートなので、表示可能文字を区切りにしてはいけない。
  ctx_rows+=("$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
    "$mark" "$cmd" "$got_feat" "$got_dev" "$depends" "$why")")
}

# 期待値が文脈で変わる形 —— current branch に依存する判定
#   これらが「develop 上で deny」なのは、**その push が実際に保護ブランチを
#   押すから**であって、テストが develop 上で走ったからではない。
ctx_case 'HEAD + && separator'  allow deny 'git push -u origin HEAD && gh pr create --base main' \
  'HEAD は current に解決 → develop を押す'
ctx_case 'HEAD + ; separator'   allow deny 'git push -u origin HEAD; gh pr create --base main' \
  '同上（区切り軸）'
ctx_case 'HEAD + || separator'  allow deny 'git push -u origin HEAD || gh pr create --base main' \
  '同上（区切り軸）'
ctx_case 'HEAD 単体'            allow deny 'git push -u origin HEAD' \
  'HEAD は current に解決 → develop を押す'
ctx_case 'bare push'            allow deny 'git push' \
  'refspec 無し → current を押す'
ctx_case 'push origin のみ'     allow deny 'git push origin' \
  'refspec 無し → current を押す'
ctx_case 'force（暗黙）'        allow deny 'git push --force' \
  '暗黙 + force。保護 current では宛先不問で deny'

# 期待値が文脈で変わらない形 —— current branch に依存しない判定
#   (B) の修正対象はここ。明示の宛先があるので current は無関係である。
ctx_case 'feature push'         allow allow 'git push origin feat/x' \
  '明示の宛先が非保護 → current と無関係'
ctx_case 'docs push'            allow allow 'git push -u origin docs/y' \
  '同上（matrix GOOD 配列と同一検体）'
ctx_case 'HEAD:feat/x'          allow allow 'git push origin HEAD:feat/x' \
  'dst が非保護'
ctx_case 'develop:feat/x'       allow allow 'git push origin develop:feat/x' \
  'ローカル develop を読み remote feat/x へ書く。保護 ref は動かない'
ctx_case 'non-push'             allow allow 'git status' \
  'push でない'

#   破壊形。宛先が保護なので current に関わらず deny。
ctx_case 'direct develop'       deny deny 'git push origin develop' \
  '宛先が保護'
ctx_case 'direct main'          deny deny 'printf ready; git push origin main' \
  '宛先が保護（区切りの後ろ）'
ctx_case 'feat/x:develop'       deny deny 'git push origin feat/x:develop' \
  'dst が保護。src だけ見ると素通しになる形'
ctx_case 'HEAD:develop'         deny deny 'git push origin HEAD:develop' \
  'dst が保護'
ctx_case 'feat/x:refs/heads/main' deny deny 'git push origin feat/x:refs/heads/main' \
  'dst が保護（完全 ref 表記）'
ctx_case '複数 refspec に保護混在' deny deny 'git push origin feat/x develop' \
  '2 つ目の refspec が保護'
ctx_case 'refspec force +HEAD:main' deny deny 'git push origin +HEAD:main || gh pr create --base feat/x' \
  '+ は --force 等価 かつ dst が保護'
ctx_case 'refspec force +feat/x:main' deny deny 'git push origin +feat/x:main' \
  '同上'
ctx_case 'mirror'               deny deny 'git push origin --mirror && gh pr create --base feat/x' \
  '全 ref 上書き'
ctx_case 'all'                  deny deny 'git push origin --all' \
  '全 ref 上書き'

echo ''
echo '=== 文脈対照表: 同じコマンドが保護／非保護でどう変わるか ==='
printf '%-2s %-52s %-8s %-8s %-14s %s\n' '' 'コマンド' 'feat/x' 'develop' '判定' '理由'
printf '%s\n' "-------------------------------------------------------------------------------------------------------"
for row in "${ctx_rows[@]}"; do
  IFS=$'\x1f' read -r m c f d dep w <<< "$row"
  printf '%-2s %-52s %-8s %-8s %-14s %s\n' "$m" "$c" "$f" "$d" "$dep" "$w"
done

printf '\n%s\n' "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
