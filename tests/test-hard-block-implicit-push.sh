#!/bin/bash
# NEGATIVE-TEST-FOR: hooks/protect-branches.sh
# NEGATIVE-TEST-FOR: hooks/git-push-guard.sh
#
# 暗黙ブランチへの push をハードブロック 2 本が止めることを固定する（F22 / F22b、2026-10-30）。
#
# 発端（統括の独立ドライラン 2026-10-30 12:00、develop の checkout 上）:
#   git push                 protect-branches rc=1  git-push-guard rc=0
#   git push origin HEAD     protect-branches rc=0  git-push-guard rc=0
#   rc=1 は「非ブロックのエラー」なので、Claude Code はそのまま push を通す。
#   サーバ側の branch protection（strict required check、enforce_admins）が最後の砦だった。
#
# 原因:
#   protect-branches.sh Check 3b は `set -euo pipefail` の下で
#     push_target=$(echo "$cmd_norm" | grep -oE "push[[:space:]]+[^|;&)<>]*" | ...)
#   を実行する。素の `git push` には `push` の後に空白が無く grep が 1 を返し、
#   pipefail + set -e で代入ごと終了する（bash -x の最終行が `push_target=`）。
#   git-push-guard.sh §2 は明示の ref しか見ず、§1 の暗黙ブランチ判定は force 限定だった。
#   どちらも `HEAD` を current に解決しない。git-push-guard.sh §2 は `xargs` が
#   奇数個の引用符で `unterminated quote` を出して rc=1 になる（2026-10-30 transcript で実測）。
#
# 軸:
#   B  陽性: 保護ブランチを更新する push は 2 本とも rc=2（暗黙・HEAD・-C・cd・.cwd・@{push}）
#   A  陰性: feature ブランチ・非保護の明示 ref・tags だけの push は 2 本とも rc=0
#   E  rc=1 はどの行にも出ない（非ブロックのエラー = 素通り）
#   L  rc=2 の行は ADR-006 台帳に hook 名つきの deny 行を 1 行以上積む
#   P  2 本が同じ hooks/lib/push_dests.py を呼び、インラインの写しを持たない
#   M  片側変異: 解決器の出力を捨てると暗黙 push が再び rc=0 になる（lib つきの対照と比べる）
#   D  配備欠落: lib が無くても rc=1 にならず、明示 ref は従来の検査が止める
#
# hook の process cwd は Bash ツールの cwd とは限らない。行ごとに process cwd と
# 入力 JSON の .cwd を分けて与え、.cwd と `-C` / `cd` の側で判定していることを固定する。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB="${PB_HOOK:-$SCRIPT_DIR/../hooks/protect-branches.sh}"
PG="${PG_HOOK:-$SCRIPT_DIR/../hooks/git-push-guard.sh}"
PASS=0; FAIL=0
export AIDD_LEDGER_SOURCE=test

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
# aidd_ledger_append は $HOME/.claude/hooks/ledger/ へ書く。hook だけを一時 HOME で
# 走らせ、本物の台帳にテスト行を積まずに「積んだこと」を数える。
HOOK_HOME="$FIX/home"
LEDGER="$HOOK_HOME/.claude/hooks/ledger/guard-ledger.jsonl"
mkdir -p "$(dirname "$LEDGER")"
: > "$LEDGER"

mkrepo() {  # mkrepo <dir> <branch>
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD "refs/heads/$2"
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$1" remote add origin "$FIX/remote.git"
}
git init -q --bare "$FIX/remote.git"
DEV="$FIX/dev"; FEAT="$FIX/feat"; UP="$FIX/up"; SPACE="$FIX/dev with space"; PLAIN="$FIX/plain"
mkrepo "$DEV" develop
git -C "$DEV" branch feat/a
git -C "$DEV" tag v1
mkrepo "$FEAT" feat/xxx
mkrepo "$SPACE" develop
mkdir -p "$PLAIN"
# feature ブランチだが push.default=upstream で上流が develop: 素の push は develop を更新する
mkrepo "$UP" feat/up
git -C "$UP" update-ref refs/remotes/origin/develop HEAD
git -C "$UP" config push.default upstream
git -C "$UP" config branch.feat/up.remote origin
git -C "$UP" config branch.feat/up.merge refs/heads/develop
# develop だが push.default=upstream で上流が review-copy: 素の push は review-copy だけを更新する
REVIEW="$FIX/review"
mkrepo "$REVIEW" develop
git -C "$REVIEW" update-ref refs/remotes/origin/review-copy HEAD
git -C "$REVIEW" config push.default upstream
git -C "$REVIEW" config branch.develop.remote origin
git -C "$REVIEW" config branch.develop.merge refs/heads/review-copy
# feature 上だが push.default=matching でローカルに develop がある: 素の push は develop も押す
MATCH="$FIX/match"
mkrepo "$MATCH" feat/m
git -C "$MATCH" branch develop
git -C "$MATCH" config push.default matching
# remote.origin.push が push.default より先に効く: develop → review-copy / feature → develop
RSPEC="$FIX/rspec"
mkrepo "$RSPEC" develop
git -C "$RSPEC" config remote.origin.push refs/heads/develop:refs/heads/review-copy
RSPEC2="$FIX/rspec2"
mkrepo "$RSPEC2" feat/rs
git -C "$RSPEC2" config remote.origin.push refs/heads/feat/rs:refs/heads/develop
# feature 上（直前は develop）でローカルに develop がある
SW="$FIX/sw"
mkrepo "$SW" develop
git -C "$SW" checkout -q -b feat/s
# develop で remote review の push refspec が develop → review-copy（--repo で選ぶ）
REPO="$FIX/repo"
mkrepo "$REPO" develop
git -C "$REPO" remote add review "$FIX/remote.git"
git -C "$REPO" config remote.review.push refs/heads/develop:refs/heads/review-copy
# develop だが push.default=upstream で merge=review-copy、remote-tracking ref は未取得
UPR="$FIX/upr"
mkrepo "$UPR" develop
git -C "$UPR" config push.default upstream
git -C "$UPR" config branch.develop.remote origin
git -C "$UPR" config branch.develop.merge refs/heads/review-copy

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# run_hook <hook> <process-cwd> <json-cwd> <cmd> → rc
run_hook() {
  local rc=0
  printf '{"session_id":"t","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' \
    "$(json_escape "$4")" "$(json_escape "$3")" \
    | (cd "$2" && HOME="$HOOK_HOME" bash "$1" >/dev/null 2>"$FIX/stderr") || rc=$?
  printf '%s' "$rc"
}

# row <expect-rc> <process-cwd> <json-cwd> <label> <cmd>
row() {
  local expect="$1" proc="$2" jcwd="$3" label="$4" cmd="$5" hook name rc before after
  for hook in "$PB" "$PG"; do
    name=$(basename "$hook" .sh)
    before=$(grep -c "\"hook\":\"$name\".*\"decision\":\"deny\"" "$LEDGER" || true)
    rc=$(run_hook "$hook" "$proc" "$jcwd" "$cmd")
    after=$(grep -c "\"hook\":\"$name\".*\"decision\":\"deny\"" "$LEDGER" || true)
    if [ "$rc" = "1" ]; then
      echo "  FAIL: [E] [$name] $label rc=1 (非ブロックのエラー = 素通り) stderr=$(head -c 160 "$FIX/stderr")"
      FAIL=$((FAIL + 1))
    elif [ "$rc" != "$expect" ]; then
      echo "  FAIL: [$name] $label expected rc=$expect actual rc=$rc cmd=$cmd"
      FAIL=$((FAIL + 1))
    elif [ "$expect" = "2" ] && [ "$after" -le "$before" ]; then
      echo "  FAIL: [L] [$name] $label rc=2 だが台帳に deny 行が増えていない (before=$before after=$after)"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS: [$name] $label rc=$rc"
      PASS=$((PASS + 1))
    fi
  done
}

echo "=== B 陽性: 保護ブランチを更新する push は rc=2 ==="
row 2 "$PLAIN" "$DEV"  "B1 develop 上の素の git push（.cwd=develop）"     'git push'
row 2 "$FEAT"  "$DEV"  "B1b process cwd が feature でも .cwd=develop なら止める" 'git push'
row 2 "$PLAIN" "$FEAT" "B2 -C <develop> の素の push（.cwd=feature）"      "git -C $DEV push"
row 2 "$PLAIN" "$DEV"  "B3 origin HEAD（develop 上）"                       'git push origin HEAD'
row 2 "$PLAIN" "$FEAT" "B4 HEAD:develop（feature 上でも宛先が develop）"    'git push origin HEAD:develop'
row 2 "$PLAIN" "$FEAT" "B5 :develop（保護ブランチの削除）"                  'git push origin :develop'
row 2 "$PLAIN" "$FEAT" "B6 origin develop"                                  'git push origin develop'
row 2 "$PLAIN" "$FEAT" "B7 -u origin develop"                               'git push -u origin develop'
row 2 "$PLAIN" "$FEAT" "B8 -C <develop> push origin develop"                "git -C $DEV push origin develop"
row 2 "$PLAIN" "$DEV"  "B9 remote だけ指定（develop 上）"                   'git push origin'
row 2 "$PLAIN" "$FEAT" "B10 cd <develop> && git push（.cwd=feature）"       "cd $DEV && git push"
row 2 "$PLAIN" "$FEAT" "B11 末尾コメントに奇数個の引用符"                   "git push origin develop # it's done"
row 2 "$PLAIN" "$FEAT" "B12 保護 ref が最後の refspec でない"               'git push origin develop feat/xxx'
row 2 "$PLAIN" "$UP"   "B13 push.default=upstream で上流が develop"         'git push'
row 2 "$PLAIN" "$DEV"  "B14 develop 上の暗黙 force（.cwd=develop）"         'git push --force'
row 2 "$PLAIN" "$FEAT" "B15 -C の値に空白（引用つき）"                      "git -C \"$SPACE\" push"
row 2 "$PLAIN" "$DEV"  "B16 @ は HEAD の別名"                               'git push origin @'
row 2 "$PLAIN" "$FEAT" "B17 -C <develop> の暗黙 force（.cwd=feature）"     "git -C $DEV push --force"
row 2 "$PLAIN" "$DEV"  "B18 refspec がコマンド置換の current"             'git push -u origin "$(git branch --show-current)"'
row 2 "$PLAIN" "$DEV"  "B19 refspec がバッククォートの current"           'git push origin `git rev-parse --abbrev-ref HEAD`'
row 2 "$PLAIN" "$FEAT" "B20 本文を実行する heredoc（bash <<EOF）"          $'bash <<\'EOF\'\ngit push origin develop\nEOF'
row 2 "$PLAIN" "$DEV"  "B21 heredoc をパイプで bash へ（データ文脈ではない）" $'cat <<\'EOF\' | bash\ngit push\nEOF'
row 2 "$PLAIN" "$FEAT" "B22 サブシェルの中で cd <develop> して push"       "(cd $DEV && git push)"
row 2 "$PLAIN" "$MATCH" "B23 push.default=matching でローカルに develop"   'git push'
row 2 "$PLAIN" "$DEV"  "B24 bash -c の中の素の push"                       'bash -c "git push"'
row 2 "$PLAIN" "$DEV"  "B25 eval の中の HEAD push"                         'eval "git push origin HEAD"'
row 2 "$PLAIN" "$FEAT" "B26 sh -c の中で cd <develop> して push"           "sh -c 'cd $DEV && git push'"
row 2 "$PLAIN" "$DEV"  "B27 switch -c の後に develop へ戻ってから push"   'git switch -c feat/z && git switch develop && git push'
row 2 "$PLAIN" "$UP"   "B28 checkout develop（remote-tracking から作成）して push" 'git checkout develop && git push'
row 2 "$PLAIN" "$RSPEC2" "B29 remote.origin.push が feature → develop"    'git push'
row 2 "$PLAIN" "$DEV"  "B30 refs/heads/* を全部写すワイルドカード"         "git push origin 'refs/heads/*:refs/heads/*'"
row 2 "$PLAIN" "$FEAT" "B31 cd -- <develop> して push"                     "cd -- $DEV && git push"
row 2 "$PLAIN" "$FEAT" "B32 src が置換でも dst が明示の develop"           'git push origin "$(git rev-parse HEAD)":refs/heads/develop'
row 2 "$PLAIN" "$DEV"  "B33 current を返す置換の変形（2>/dev/null）"       'git push origin "$(git branch --show-current 2>/dev/null)"'
row 2 "$PLAIN" "$DEV"  "B34 current を返す置換の変形（@）"                 'git push origin "$(git rev-parse --abbrev-ref @)"'
row 2 "$PLAIN" "$DEV"  "B35 current を返す置換の変形（パイプ）"            'git push -u origin "$(git branch --show-current | tr -d x)"'
row 2 "$PLAIN" "$DEV"  "B36 置換を代入した変数の refspec"                  'BRANCH=$(git rev-parse --abbrev-ref HEAD) && git push -u origin "$BRANCH"'
row 2 "$PLAIN" "$FEAT" "B37 変数に入れた develop"                          'B=develop; git push origin "$B"'
row 2 "$PLAIN" "$FEAT" "B38 計算で決まる宛先は止める（feature 上でも）"   'git push origin "$(printf feat/x)"'
row 2 "$PLAIN" "$UP"   "B39 checkout -t origin/develop して push"          'git checkout -t origin/develop && git push'
row 2 "$PLAIN" "$SW"   "B40 checkout -（直前の develop へ戻る）して push"  'git checkout - && git push'
row 2 "$PLAIN" "$DEV"  "B41 git -P push（早期 exit をすり抜けない）"        'git -P push'
row 2 "$PLAIN" "$DEV"  "B42 git --work-tree=. push origin HEAD"            'git --work-tree=. push origin HEAD'
row 2 "$PLAIN" "$DEV"  "B43 git --literal-pathspecs push"                  'git --literal-pathspecs push'
row 2 "$PLAIN" "$DEV"  "B44 行継続 git \\⏎push"                           $'git \\\npush'
row 2 "$PLAIN" "$DEV"  "B45 行継続 git push \\⏎ origin"                    $'git push \\\n  origin'
row 2 "$PLAIN" "$FEAT" "B46 行継続で割った develop"                       $'git push origin dev\\\nelop'
row 2 "$PLAIN" "$FEAT" "B47 既定ブランチを計算する HEAD:\"$(… | sed)\""      'git push origin HEAD:"$(git symbolic-ref --short refs/remotes/origin/HEAD | sed s@^origin/@@)"'
row 2 "$PLAIN" "$FEAT" "B48 for ループ変数の refspec"                      'for b in develop; do git push origin "$b"; done'
row 2 "$PLAIN" "$FEAT" "B49 \${B:-develop} の既定値"                        'git push origin "${B:-develop}"'
row 2 "$PLAIN" "$FEAT" "B50 関数の \$1"                                     'f() { git push origin "$1"; }; f develop'
row 2 "$PLAIN" "$SW"   "B51 --branches（ローカルに develop）"               'git push --branches origin'
row 2 "$PLAIN" "$SW"   "B52 matching refspec :"                            'git push origin :'
row 2 "$PLAIN" "$FEAT" "B53 --mirror"                                      'git push --mirror origin'
row 2 "$PLAIN" "$DEV"  "B54 bash -lc"                                      'bash -lc "git push"'
row 2 "$PLAIN" "$DEV"  "B55 bash -c --"                                    'bash -c -- "git push"'
row 2 "$PLAIN" "$FEAT" "B56 -c alias.p=push の alias"                      'git -c alias.p=push p origin develop'
row 2 "$PLAIN" "$FEAT" "B57 xargs が refspec を与える"                      'echo develop | xargs git push origin'
row 2 "$PLAIN" "$DEV"  "B58 \$G push（変数の git）"                         'G=git; $G push'
row 2 "$PLAIN" "$FEAT" "B59 \$'\\x64evelop'（ANSI-C 引用）"                 "git push origin \$'\\x64evelop'"
row 2 "$PLAIN" "$FEAT" "B60 --prune + ワイルドカード（削除しうる）"         "git push --prune origin 'refs/heads/*:refs/heads/*'"
row 2 "$PLAIN" "$DEV"  "B61 置換はシェルの cwd（develop）で評価: -C <feature> へ develop" "git -C $SW push origin \"\$(git branch --show-current)\""
row 2 "$PLAIN" "$FEAT" "B62 サブシェル内の代入は外へ漏れない（外は develop）" 'B=develop; (B=feat/x); git push origin "$B"'
row 2 "$PLAIN" "$DEV"  "B63 heredoc を tee 経由で bash へ"                  $'cat <<\'EOF\' | tee note.md | bash\ngit push\nEOF'
row 2 "$PLAIN" "$FEAT" "B64 eval の cd は現在のシェルに残る（develop へ）"   "eval \"cd $DEV\"; git push origin HEAD"

echo ""
echo "=== A 陰性: 保護ブランチを更新しない push は rc=0 ==="
row 0 "$PLAIN" "$FEAT" "A1 feature 上の素の git push"                       'git push'
row 0 "$DEV"   "$FEAT" "A1b process cwd が develop でも .cwd=feature なら通す" 'git push'
row 0 "$PLAIN" "$DEV"  "A2 origin release/v0.9.2（develop 上）"             'git push origin release/v0.9.2'
row 0 "$PLAIN" "$DEV"  "A3 origin feat/xxx（develop 上）"                   'git push origin feat/xxx'
row 0 "$PLAIN" "$DEV"  "A4 -u origin feat/xxx（develop 上）"                'git push -u origin feat/xxx'
row 0 "$PLAIN" "$DEV"  "A5 -C <feature> の素の push（.cwd=develop）"        "git -C $FEAT push"
row 0 "$PLAIN" "$DEV"  "A6 cd <feature> && git push（.cwd=develop）"        "cd $FEAT && git push"
row 0 "$PLAIN" "$FEAT" "A7 origin HEAD（feature 上）"                       'git push origin HEAD'
row 0 "$PLAIN" "$DEV"  "A8 HEAD:feat/xxx（develop 上でも宛先は feature）"   'git push origin HEAD:feat/xxx'
row 0 "$PLAIN" "$DEV"  "A9 develop:feat/xxx（宛先は feature）"              'git push origin develop:feat/xxx'
row 0 "$PLAIN" "$DEV"  "A10 tag だけの明示 push（develop 上）"              'git push origin v1.0.0'
row 0 "$PLAIN" "$DEV"  "A11 feature の削除（develop 上）"                   'git push origin --delete feat/old'
row 0 "$PLAIN" "$FEAT" "A12 feature 上の素の push + 末尾コメント"           "git push # it's done"
row 0 "$DEV"   "$DEV"  "A13 -C <feature> の暗黙 force（.cwd=develop）"     "git -C $FEAT push --force"
row 0 "$DEV"   "$FEAT" "A14 feature 上の暗黙 force（process cwd=develop）" 'git push --force'
row 0 "$PLAIN" "$FEAT" "A15 refspec がコマンド置換の current（feature 上）" 'git push -u origin "$(git branch --show-current)"'
# A16/A17 は develop 上（.cwd=develop）で、本文が暗黙 push。解決器が本文を読めば block になる。
# 本文が `git push origin develop` のような**明示**の保護 ref だと、従来からある
# 明示 ref の検査（Check 3b / §2、heredoc を区別しない）が block する。
# ac1fa58 でも rc=2 で、この変更の前からある誤検知。ここでは固定しない（PR に follow-up）。
row 0 "$PLAIN" "$DEV"  "A16 データ heredoc の本文（cat <<EOF > note.md）"  $'cat <<\'EOF\' > note.md\ngit push\ngit push origin HEAD\nEOF'
row 0 "$PLAIN" "$DEV"  "A17 PR 本文の heredoc（gh pr create --body に cat <<EOF の置換）" \
  $'gh pr create --title t --body "$(cat <<\'EOF\'\nrun git push, then git push origin HEAD\nEOF\n)"'
row 0 "$PLAIN" "$FEAT" "A18 サブシェルの cd は外へ持ち越さない"           "(cd $DEV && git status); git push"
row 0 "$PLAIN" "$UP"   "A19 -c push.default=current は呼び出しの設定で判定" 'git -c push.default=current push'
row 0 "$PLAIN" "$REVIEW" "A20 develop だが @{push} が review-copy"        'git push'
row 0 "$PLAIN" "$FEAT" "A21 current を返す置換を代入した変数（feature 上）" 'BRANCH=$(git branch --show-current) && git push -u origin "$BRANCH"'
row 0 "$PLAIN" "$FEAT" "A43 current を返す置換 + 2>/dev/null（feature 上）" 'git push origin "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"'
row 0 "$PLAIN" "$DEV"  "A22 末尾が \$ のリテラル ref"                      'git push origin HEAD:feat/cost$'
row 0 "$PLAIN" "$DEV"  "A23 bash -c の中で cd <feature> して push"         "bash -c 'cd $FEAT && git push'"
row 0 "$PLAIN" "$FEAT" "A24 bash -c の中の cd は外へ持ち越さない"          "bash -c 'cd $DEV && git status'; git push"
row 0 "$PLAIN" "$DEV"  "A25 switch -c してから HEAD を push（develop 上）" 'git switch -c feat/new && git push -u origin HEAD'
row 0 "$PLAIN" "$DEV"  "A26 checkout -b してから素の push（develop 上）"   'git checkout -b feat/new2 && git push'
row 0 "$PLAIN" "$FEAT" "A27 checkout -- <path> は HEAD を変えない"         'git checkout -- README.md && git push'
row 0 "$PLAIN" "$DEV"  "A28 echo の引数の git push（追記）"                'echo git push >> note.md'
row 0 "$PLAIN" "$DEV"  "A29 echo の引数の git push（連鎖）"                'echo git push && git status'
row 0 "$PLAIN" "$RSPEC" "A30 remote.origin.push が develop → review-copy" 'git push'
row 0 "$PLAIN" "$DEV"  "A31 tags だけのワイルドカード"                     "git push origin 'refs/tags/*:refs/tags/*'"
row 0 "$PLAIN" "$DEV"  "A32 feat/* だけのワイルドカード"                   "git push origin 'refs/heads/feat/*:refs/heads/feat/*'"
row 0 "$PLAIN" "$UPR"  "A33 upstream の merge=review-copy（追跡 ref 未取得）" 'git push'
row 0 "$PLAIN" "$DEV"  "A34 cd -- <feature> して HEAD を push"            "cd -- $FEAT && git push origin HEAD"
row 0 "$PLAIN" "$DEV"  "A35 switch --create=<b> の結合形"                  'git switch --create=feat/new3 && git push -u origin HEAD'
row 0 "$PLAIN" "$DEV"  "A36 checkout -b<b> の結合形"                       'git checkout -bfeat/new4 && git push -u origin HEAD'
row 0 "$PLAIN" "$DEV"  "A37 command echo の引数の git push"                'command echo git push >> note.md'
row 0 "$PLAIN" "$DEV"  "A38 env echo の引数の git push"                    'env echo git push >> note.md'
row 0 "$PLAIN" "$DEV"  "A39 読めない cd（変数）は不明 = 止めない"          'cd "$UNSET_DIR_F22" && git push'
row 0 "$PLAIN" "$DEV"  "A40 tag を checkout（detached）して HEAD を push"   'git checkout v1 && git push origin HEAD'
row 0 "$PLAIN" "$SW"   "A41 checkout <branch> -- <path> は HEAD を変えない" 'git checkout develop -- README.md && git commit -m x && git push'
row 0 "$PLAIN" "$DEV"  "A42 変数に入れた feature"                          'B=feat/q; git push origin "$B"'
row 0 "$PLAIN" "$FEAT" "A44 置換はシェルの cwd（feature）で評価: -C <develop> へ feature" "git -C $DEV push origin \"\$(git branch --show-current)\""
row 0 "$PLAIN" "$DEV"  "A45 サブシェル内の代入は外へ漏れない（外は feature）" 'B=feat/x; (B=develop); git push origin "$B"'
row 0 "$PLAIN" "$REPO" "A46 --repo review の push refspec（develop → review-copy）" 'git push --repo review'
row 0 "$PLAIN" "$REPO" "A47 --repo=review の push refspec"                 'git push --repo=review'
row 0 "$PLAIN" "$DEV"  "A48 heredoc を tee へ（データ）"                    $'cat <<\'EOF\' | tee note.md\ngit push origin HEAD\nEOF'
row 0 "$PLAIN" "$DEV"  "A49 eval の cd は現在のシェルに残る（feature へ）"   "eval \"cd $FEAT\"; git push origin HEAD"

echo ""
echo "=== P 対: 2 本が同じ lib を呼び、写しを持たない ==="
LIB_LINE='_PUSH_DESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/push_dests.py"'
CALL='python3 "$_PUSH_DESTS" "$cmd" "$_push_base"'
for hook in "$PB" "$PG"; do
  name=$(basename "$hook" .sh)
  nl=$(grep -cF "$LIB_LINE" "$hook" || true)
  nc=$(grep -cF "$CALL" "$hook" || true)
  ni=$(grep -c "_push_dests_py" "$hook" || true)
  if [ "$nl" = 1 ] && [ "$nc" = 1 ] && [ "$ni" = 0 ]; then
    echo "  PASS: [P] [$name] lib/push_dests.py を 1 回呼ぶ（path=$nl call=$nc inline=$ni）"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [P] [$name] lib の呼び出しが崩れている（path=$nl call=$nc inline=$ni、期待 1/1/0）"; FAIL=$((FAIL + 1))
  fi
done
LIB="$(dirname "$PB")/lib/push_dests.py"
if [ -f "$LIB" ] && [ "$(dirname "$PB")" = "$(dirname "$PG")" ]; then
  echo "  PASS: [P] 2 本の lib は同じファイル ($(shasum -a 256 "$LIB" | cut -c1-12))"; PASS=$((PASS + 1))
else
  echo "  FAIL: [P] lib が無い、または 2 本が別の hooks dir (pb=$(dirname "$PB") pg=$(dirname "$PG") lib_exists=$([ -f "$LIB" ] && echo 1 || echo 0))"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M 片側変異: 解決器の出力を捨てると暗黙 push が通る ==="
# hooks ツリーを lib ごと複製し、解決器の呼び出し 1 行だけを空出力に差し替える。
# 対照（未変異の複製）で B1 が rc=2 であることを先に確かめる: lib を欠いた複製は
# 「変異で反転した」ではなく「動かなかった」になるので変異の証明にならない。
# 明示の B6 は従来の明示 ref 検査が残るので rc=2 のまま（変異が解決器だけに効く確認）。
MUT_DIR="$FIX/mut"; CTL_DIR="$FIX/ctl"
mkdir -p "$MUT_DIR" "$CTL_DIR"
cp -R "$(dirname "$PB")/lib" "$MUT_DIR/lib"
cp -R "$(dirname "$PB")/lib" "$CTL_DIR/lib"
for hook in "$PB" "$PG"; do
  name=$(basename "$hook" .sh)
  CTL="$CTL_DIR/$name.sh"; MUT="$MUT_DIR/$name.sh"
  cp "$hook" "$CTL"
  python3 - "$hook" "$MUT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'python3 "$_PUSH_DESTS"'
assert src.count(old) == 1, "mutation target missing: resolver call (count=%d)" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "true"))
PY
  rc_ctl=$(run_hook "$CTL" "$PLAIN" "$DEV" 'git push')
  rc=$(run_hook "$MUT" "$PLAIN" "$DEV" 'git push')
  if [ "$rc_ctl" = "2" ] && [ "$rc" = "0" ]; then
    echo "  PASS: [M] [$name] B1 は対照で rc=2、変異版で rc=0（このテストは解決器の欠落を検出する）"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [M] [$name] B1 対照 rc=$rc_ctl（期待 2）変異 rc=$rc（期待 0）"; FAIL=$((FAIL + 1))
  fi
  rc=$(run_hook "$MUT" "$PLAIN" "$FEAT" 'git push origin develop')
  if [ "$rc" = "2" ]; then
    echo "  PASS: [M] [$name] 変異版でも明示 B6 は rc=2"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [M] [$name] 変異版で明示 B6 が rc=$rc"; FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== D 配備欠落: lib/push_dests.py が無い hooks dir ==="
# 配備で lib が欠けた場合（F16 の古い checkout からの自動配備など）。暗黙 push は
# 止められなくなるが、rc=1（素通りのエラー）にはならず、明示 ref は従来の検査が止める。
NOLIB="$FIX/nolib"
mkdir -p "$NOLIB"
cp -R "$(dirname "$PB")/lib" "$NOLIB/lib"
rm -f "$NOLIB/lib/push_dests.py"
for hook in "$PB" "$PG"; do
  name=$(basename "$hook" .sh)
  cp "$hook" "$NOLIB/$name.sh"
  rc_imp=$(run_hook "$NOLIB/$name.sh" "$PLAIN" "$DEV" 'git push')
  rc_exp=$(run_hook "$NOLIB/$name.sh" "$PLAIN" "$FEAT" 'git push origin develop')
  if [ "$rc_imp" != "1" ] && [ "$rc_exp" = "2" ]; then
    echo "  PASS: [D] [$name] lib 欠落: 暗黙 rc=$rc_imp（1 でない）、明示 develop rc=2"; PASS=$((PASS + 1))
  else
    echo "  FAIL: [D] [$name] lib 欠落: 暗黙 rc=$rc_imp（1 は不可）明示 develop rc=$rc_exp（期待 2）"; FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
