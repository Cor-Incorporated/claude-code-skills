#!/usr/bin/env bash
# repo-janitor.sh — worktree/ブランチの安全な掃除。デフォルトは dry-run（計画表示のみ）
# 使い方:
#   repo-janitor.sh <repoパス>            # dry-run: 削除候補の一覧と理由を表示するだけ
#   repo-janitor.sh <repoパス> --apply    # ローカルの削除を実行（マージ済みのみ、-d 安全削除）
#   repo-janitor.sh <repoパス> --apply --remote  # マージ済みリモートブランチも削除
# 安全装置:
#   - 保護ブランチ (main/master/develop/stg) は絶対に触らない
#   - 基準ブランチに入ってから MIN_AGE_DAYS 日未満のものは消さない（rules/git-workflow.md の
#     「機械掃除は マージ済み + 7 日 限定」。数値は tests/test-pairs-link.sh の pair19 が照合する）
#   - worktree と、自分のコミットが無いブランチ（先端が基準ブランチの first-parent 上にある）は、
#     作られてから MIN_AGE_DAYS 日未満なら消さない。作られた日は reflog の最も古い記録で測り、
#     分からなければ消さない
#   - 未マージブランチは削除しない（git branch -d のみ、-D は使わない）
#   - 消すと失われる作業がある worktree はスキップして警告（hidden_work）: 設定（status.showUntrackedFiles=no）で
#     隠れる未追跡ファイル、assume-unchanged / skip-worktree で git status に出ない変更、lossy な clean filter
#     （nbstripout など）で git status に出ない作業ツリーの中身。ignore されたファイルも、handover の撤収基準 3 が
#     「再生成可能」と列挙したもの（REGENERABLE_IGNORED）以外があれば残す。--apply は消す直前にも確かめ直す
#     （計画から削除までの間に gh の問い合わせで数秒ある）
#   - ロックされた worktree は消さない
#   - 計画は prune の前の worktree の一覧で立てる（--apply でも承認した dry-run と同じ計画になる）。
#     ディレクトリが見つからない worktree の管理情報は、最後に使われてから MIN_AGE_DAYS 日を過ぎたものだけ
#     片付ける（git worktree prune --expire。index の無い worktree は git が日数を見ずに片付ける）。
#     片付けた worktree のブランチは、次の実行の dry-run に出てから消える
#   - 現在checkout中のブランチ、渡されたパスの worktree、呼び出し元がいる worktree は触らない
#   - open PR の有無を gh で確かめられないリモートブランチは消さない。origin が GitHub の URL でなければ
#     確かめられないとみなす。origin が fork なら祖先のリポジトリ（親、その親…）の PR も見る。そのブランチを
#     base にする open PR（stacked PR）があっても消さない。残す worktree で checkout 中のブランチのリモートも
#     消さない（--apply では消す直前に、今も checkout 中でないことを確かめ直す）。消すときは refs/heads/ を
#     指定し（同じ名前のタグを消さない）、fetch したときの先端から動いていないことを --force-with-lease で確かめる
#   - fetch に失敗したらリモートは消さない
#   - --apply --remote ではリモートを先に消す（upstream が残っていると git branch -d が拒否する）
# dry-run も git fetch --prune で origin の追跡ブランチを更新する。--apply は計画を作り直すので、
# 承認した dry-run の直後に実行する（日付をまたぐと 7 日を越えた分が候補に加わりうる）
set -uo pipefail
# 呼び出し元の git 環境（hook の中など）を引き継ぐと、渡したパスではなく別のリポジトリを掃除してしまう
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

MIN_AGE_DAYS=7
# handover の撤収基準 3 が「再生成可能」と列挙したもの（skills/handover/common-clauses.md の表。
# 実測で現れたものだけを載せる規定。pair19 が表と照合する）
REGENERABLE_IGNORED=('**/__pycache__/**' '*.pyc')
# fork の祖先をたどる上限（これより深ければ確かめられないとみなす）
GH_PARENT_DEPTH=5

REPO="${1:?usage: repo-janitor.sh <repo-path> [--apply] [--remote]}"
shift
APPLY=false; REMOTE=false
for a in "$@"; do
  case "$a" in
    --apply) APPLY=true ;;
    --remote) REMOTE=true ;;
  esac
done

PROTECTED='^(main|master|develop|stg|staging|production)$'
CALLER_PWD=$(pwd -P)
# cd に失敗したまま進むと、今いるディレクトリのリポジトリを掃除してしまう
cd "$REPO" || { echo "ERROR: $REPO へ移動できない" >&2; exit 1; }
REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: $REPO は git リポジトリではない" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1
REPO_ROOT=$(pwd -P)

FETCH_OK=true
git fetch --prune origin >/dev/null 2>&1 || {
  FETCH_OK=false
  echo "WARN: fetch失敗（オフライン?）。ローカル情報のみで判定し、リモートは消さない。"
}

# 統合ブランチの決定 (develop 優先)。fetch の後で選ぶ（前回の fetch 以降に作られた develop を見落とさない）
if git show-ref --verify --quiet refs/remotes/origin/develop; then BASE=origin/develop
elif git show-ref --verify --quiet refs/remotes/origin/main; then BASE=origin/main
else BASE=origin/master; fi
BASE_NAME=${BASE#origin/}
# git へは完全な名前で渡す。短い名前は、refs/heads/origin/develop のようなローカルブランチがあると
# そちらに解決され、基準ブランチに入っていないものをマージ済みと判定してしまう
BASE_REF="refs/remotes/$BASE"

# gh は upstream remote を origin より優先して別のリポジトリの PR を見ることがあるので、origin を明示する。
# URL は insteadOf を展開する前の設定値から取る（ミラーへ振り向けていても GitHub 上の名前で PR を探す）
GH_REPO_ARGS=()
origin_slug=$(git config --get remote.origin.url 2>/dev/null \
  | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
[ -n "$origin_slug" ] && GH_REPO_ARGS=(-R "$origin_slug")
# origin が fork なら、PR は祖先のリポジトリ（親、fork の fork なら親の親…）にも出ている。たどり切れなければ
# （gh が答えない・GH_PARENT_DEPTH より深い）確かめられないとみなし、リモートは消さない。origin が GitHub の
# URL でなければ、gh がどのリポジトリの PR を見るか分からないので、これも確かめられないとみなす
GH_PARENTS=()
GH_PARENTS_OK=false
if [ -n "$origin_slug" ]; then
  _repo=$origin_slug
  for _ in $(seq "$GH_PARENT_DEPTH"); do
    _parent=$(gh repo view "$_repo" --json parent \
      -q 'if .parent then .parent.owner.login + "/" + .parent.name else "" end' 2>/dev/null) || break
    if [ -z "$_parent" ]; then
      GH_PARENTS_OK=true
      break
    fi
    GH_PARENTS+=("$_parent")
    _repo=$_parent
  done
fi

in_list() { # $1=値 $2...=リスト
  local x="$1" y
  shift
  for y in "$@"; do [ "$y" = "$x" ] && return 0; done
  return 1
}
real_path() {
  (cd "$1" 2>/dev/null && pwd -P)
}

NOW=$(date +%s)
AGE_LIMIT=$((MIN_AGE_DAYS * 86400))
# 基準ブランチの first-parent を古い順に並べる（bash 3.2 には mapfile が無い）
FP=()
while IFS= read -r c; do FP+=("$c"); done < <(git rev-list --first-parent --reverse "$BASE_REF" 2>/dev/null)

# too_young <commit>: 基準ブランチに入ってから MIN_AGE_DAYS 日未満なら 0 を返し、ENTERED に入った日を入れる。
# 入った日 = first-parent を二分探索して、commit を含む最初のコミットの日付。
# `git log --first-parent --ancestry-path <commit>..<base> | tail -1` は、commit 自身が
# first-parent 上にあると次のコミットの日付を返す（1 つずれる）ので使わない。
# commit 自身が first-parent 上にある（自分のコミットが無い）ときは ON_CHAIN=true にする。
# 判定できないときは若い側（消さない側）に倒す
ENTERED="?"
ON_CHAIN=false
too_young() {
  local lo=0 hi mid ts
  ENTERED="?"
  ON_CHAIN=false
  hi=$((${#FP[@]} - 1))
  [ "$hi" -ge 0 ] || return 0
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2))
    if git merge-base --is-ancestor "$1" "${FP[$mid]}" 2>/dev/null; then hi=$mid; else lo=$((mid + 1)); fi
  done
  git merge-base --is-ancestor "$1" "${FP[$lo]}" 2>/dev/null || return 0
  read -r ts ENTERED < <(git -c log.showSignature=false log -1 --format='%ct %cs' "${FP[$lo]}")
  case "$ts" in '' | *[!0-9]*) ENTERED="?"; return 0 ;; esac
  [ "$(git rev-parse --verify --quiet "$1^{commit}")" = "${FP[$lo]}" ] && ON_CHAIN=true
  [ $((NOW - ts)) -lt "$AGE_LIMIT" ]
}

# created_recently <dir> <ref>: ref の reflog の最も古い記録が MIN_AGE_DAYS 日未満か、記録が無ければ 0。
# CREATED に作られた日（分からなければ unknown）を入れる
CREATED="unknown"
created_recently() {
  local e
  CREATED="unknown"
  e=$(git -C "$1" reflog show --date=unix --format=%gd "$2" 2>/dev/null | tail -1 \
    | sed -nE 's/.*@\{([0-9]+)\}$/\1/p')
  [ -n "$e" ] || return 0
  CREATED=$(date -r "$e" +%F 2>/dev/null || date -d "@$e" +%F 2>/dev/null || echo "$e")
  [ $((NOW - e)) -lt "$AGE_LIMIT" ]
}

# regenerable <path>: REGENERABLE_IGNORED のどれかに当たれば 0（先頭に / を付けて ** を先頭の要素にも当てる）
regenerable() {
  local pat
  for pat in "${REGENERABLE_IGNORED[@]}"; do
    # shellcheck disable=SC2053 # 右辺は意図して glob として照合する
    [[ "/$1" == $pat ]] && return 0
  done
  return 1
}

# observed_young <commit>: 手元の origin/<base> の reflog で、commit を初めて含んだ記録が MIN_AGE_DAYS 日未満か、
# 記録が無ければ 0。自分のコミットが無い（fast-forward で入った）先端は、コミットの日付では入った日が
# 分からないので、こちらで測る
observed_young() {
  local line h e first=""
  while IFS= read -r line; do
    h=${line%% *}
    e=$(printf '%s\n' "$line" | sed -nE 's/.*@\{([0-9]+)\}$/\1/p')
    [ -n "$e" ] || continue
    if git merge-base --is-ancestor "$1" "$h" 2>/dev/null && { [ -z "$first" ] || [ "$e" -lt "$first" ]; }; then
      first=$e
    fi
  done < <(git reflog show --date=unix --format='%H %gd' "$BASE_REF" 2>/dev/null)
  [ -n "$first" ] || return 0
  ENTERED=$(date -r "$first" +%F 2>/dev/null || date -d "@$first" +%F 2>/dev/null || echo "$first")
  [ $((NOW - first)) -lt "$AGE_LIMIT" ]
}

# unregenerable_ignored <worktree>: ignore されたファイルのうち、再生成可能と列挙されていないものを出す。
# 調べられなければ 1 を返す
unregenerable_ignored() {
  local st line
  st=$(git -C "$1" status --porcelain --ignored=traditional --untracked-files=all 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in '!! '*) ;; *) continue ;; esac
    regenerable "${line#!! }" || printf '%s\n' "${line#!! }"
  done <<<"$st"
  return 0
}

# lossy_filtered <worktree>: clean filter（nbstripout など）の付いた追跡中のファイルのうち、作業ツリーの中身が
# index の blob と違うものを出す。lossy な filter を通すと HEAD と同じに見えるので git status に出ない
# （git worktree remove も同じ理由で見落として消す）。Git LFS は作業ツリーと index が常に違うので除く。
# 調べられなければ 1 を返す
lossy_filtered() {
  local files f raw idx
  files=$(git -C "$1" ls-files -- ':(exclude,attr:!filter)' ':(exclude,attr:-filter)' \
    ':(exclude,attr:filter=lfs)' 2>/dev/null) || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$1/$f" ] || continue
    raw=$(git -C "$1" hash-object --no-filters -- "$f" 2>/dev/null) || return 1
    idx=$(git -C "$1" --literal-pathspecs ls-files -s -- "$f" 2>/dev/null | awk 'NR == 1 {print $2}')
    [ "$raw" = "$idx" ] || printf '%s\n' "$f"
  done <<<"$files"
  return 0
}

# hidden_work <worktree>: 消すと失われる作業（ignore されたファイルを除く）があれば、理由を 1 行出して 0。
# 無ければ 1。調べられなければ 0（消さない側）
hidden_work() {
  local wt="$1" st flags lossy
  # 設定（status.showUntrackedFiles=no など）で隠れる未追跡ファイルも数える
  if ! st=$(git -C "$wt" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null); then
    echo "状態を確かめられない"
    return 0
  fi
  if [ -n "$st" ]; then
    echo "dirty $(printf '%s\n' "$st" | wc -l | tr -d ' ')files"
    return 0
  fi
  # assume-unchanged / skip-worktree の付いたファイルは、書き換えても git status に出ない
  # （git worktree remove も同じ理由で見落として消す）。ls-files -v では小文字と S になる
  if ! flags=$(git -C "$wt" ls-files -v 2>/dev/null); then
    echo "状態を確かめられない"
    return 0
  fi
  if printf '%s\n' "$flags" | grep -q '^[a-zS] '; then
    echo "変更が git status に出ないファイルがある: assume-unchanged / skip-worktree"
    return 0
  fi
  if ! lossy=$(lossy_filtered "$wt"); then
    echo "状態を確かめられない"
    return 0
  fi
  if [ -n "$lossy" ]; then
    echo "clean filter で git status に出ない中身がある: $(printf '%s\n' "$lossy" | head -3 | tr '\n' ' ')"
    return 0
  fi
  return 1
}

# git の拒否メッセージを 1 行にする（hint は落とす）
reason() {
  printf '%s\n' "$1" | grep -v '^hint:' | tr -s ' \n' ' ' | sed 's/ $//'
}

MODE="DRY-RUN（計画のみ・変更なし）"; $APPLY && MODE="APPLY（削除実行）"
echo "# repo-janitor: $(basename "$REPO_ROOT") — $MODE"
echo "基準ブランチ: ${BASE}（入ってから ${MIN_AGE_DAYS} 日を過ぎたものだけ消す）"
echo ""

CURRENT=$(git branch --show-current)

# ---- 1) worktree ----
echo "## Worktrees"
# 計画は prune の前の一覧で立てる。--apply だけ先に prune すると、承認した dry-run で「checkout 中」として
# 残したブランチを、ディレクトリの消えた worktree の管理情報と一緒に外して消してしまう
WT_SNAPSHOT=$(git worktree list --porcelain)
# ディレクトリが見つからない worktree の管理情報は、最後に使われてから（その worktree の index が
# 書かれてから）MIN_AGE_DAYS 日を過ぎたものだけ片付ける。外付けディスクを外しているだけの worktree を、
# 戻ってくる前に切り離さない（index の無い worktree は、git が日数を見ずに片付ける）
PRUNE_EXPIRE="${MIN_AGE_DAYS}.days.ago"
if $APPLY; then
  git worktree prune -v --expire "$PRUNE_EXPIRE" 2>&1 | sed 's/^/- PRUNED: /'
else
  git worktree prune -n -v --expire "$PRUNE_EXPIRE" 2>&1 | sed 's/^/- PRUNE 候補: /'
fi
MAIN_WT=$(printf '%s\n' "$WT_SNAPSHOT" | sed -n 's/^worktree //p' | head -1)
WT_LOCKED=$(printf '%s\n' "$WT_SNAPSHOT" | awk '/^worktree /{wt = substr($0, 10)} /^locked( |$)/{print wt}')
WT_REMOVE=()  # 消す worktree
while IFS= read -r wt; do
  [ "$wt" = "$MAIN_WT" ] && continue
  br=$(git -C "$wt" branch --show-current 2>/dev/null || echo "?")
  # 渡されたパスの worktree と、呼び出し元がいる worktree は消さない（自分の足場を消さない）
  real=$(real_path "$wt")
  if [ -n "$real" ]; then
    case "$CALLER_PWD/" in
      "$real"/*)
        echo "- SKIP (この実行が使っている worktree): $wt [$br]"
        continue ;;
    esac
    if [ "$real" = "$REPO_ROOT" ]; then
      echo "- SKIP (この実行が使っている worktree): $wt [$br]"
      continue
    fi
  fi
  # ロックされた worktree は消さない（git worktree remove も拒否するので、計画に出すと承認した内容と
  # 実行が食い違う）
  if printf '%s\n' "$WT_LOCKED" | grep -qxF -- "$wt"; then
    echo "- SKIP (locked): $wt [$br]"
    continue
  fi
  if why=$(hidden_work "$wt"); then
    echo "- SKIP (${why}): $wt [$br]"
    continue
  fi
  if echo "$br" | grep -Eq "$PROTECTED"; then
    echo "- SKIP (protected): $wt [$br]"
    continue
  fi
  if [ -n "$br" ] && git merge-base --is-ancestor "refs/heads/$br" "$BASE_REF" 2>/dev/null; then
    if too_young "refs/heads/$br"; then
      echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $wt [$br]"
      continue
    fi
    if created_recently "$wt" HEAD; then
      echo "- KEEP (worktree created $CREATED, < $MIN_AGE_DAYS days or unknown): $wt [$br]"
      continue
    fi
    if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/heads/$br"; then
      echo "- KEEP (no own commits, branch created $CREATED, < $MIN_AGE_DAYS days or unknown): $wt [$br]"
      continue
    fi
    if $ON_CHAIN && observed_young "refs/heads/$br"; then
      echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $wt [$br]"
      continue
    fi
    # ignore されたファイルも、再生成可能と列挙されたもの以外があれば残す（git worktree remove は一緒に消す）
    if ! ignored=$(unregenerable_ignored "$wt"); then
      echo "- SKIP (ignore されたファイルを確かめられない): $wt [$br]"
      continue
    fi
    if [ -n "$ignored" ]; then
      echo "- SKIP (ignore されたファイルがある: $(printf '%s\n' "$ignored" | head -3 | tr '\n' ' ')): $wt [$br]"
      continue
    fi
    WT_REMOVE+=("$wt")
    echo "- 削除候補: $wt [$br] — $BASE にマージ済み（${ENTERED}）・clean"
  else
    echo "- KEEP (unmerged): $wt [$br]"
  fi
done < <(printf '%s\n' "$WT_SNAPSHOT" | sed -n 's/^worktree //p')
echo ""

# 残す worktree（消さないものすべて。main worktree も含む）で checkout 中のブランチ。ローカルもリモートも、
# これに当たるものは消さない（同じブランチを 2 つの worktree で checkout していて片方だけ消す場合も残す）
KEPT_BRANCHES=""
while IFS=$'\t' read -r p b; do
  [ -n "$p" ] || continue
  in_list "$p" ${WT_REMOVE[@]+"${WT_REMOVE[@]}"} && continue
  KEPT_BRANCHES="$KEPT_BRANCHES$b"$'\n'
done < <(printf '%s\n' "$WT_SNAPSHOT" | awk '/^worktree /{wt = substr($0, 10)} /^branch /{print wt "\t" substr($0, 8)}')
kept_checkout() { # $1=ブランチ名
  printf '%s' "$KEPT_BRANCHES" | grep -qxF -- "refs/heads/$1"
}

# ---- 2) ローカルブランチ（マージ済みのみ） ----
# %(refname:short) は同じ名前のタグがあると heads/<name> と表示するので、lstrip=2 で名前を取る
echo "## ローカルブランチ（$BASE にマージ済み）"
LOCAL_DELETE=()
while IFS= read -r br; do
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue
  [ "$br" = "$CURRENT" ] && { echo "- SKIP (current): $br"; continue; }
  if too_young "refs/heads/$br"; then
    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"
    continue
  fi
  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/heads/$br"; then
    echo "- KEEP (no own commits, created $CREATED, < $MIN_AGE_DAYS days or unknown): $br"
    continue
  fi
  if $ON_CHAIN && observed_young "refs/heads/$br"; then
    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): $br"
    continue
  fi
  # 残す worktree で checkout 中のブランチは消さない。消す worktree のブランチは、その worktree と一緒に候補にする
  if kept_checkout "$br"; then
    echo "- SKIP (checked out in worktree): $br"
    continue
  fi
  if printf '%s\n' "$WT_SNAPSHOT" | grep -qxF -- "branch refs/heads/$br"; then
    echo "- 削除候補: ${br}（${ENTERED}、worktree と一緒に）"
  else
    echo "- 削除候補: ${br}（${ENTERED}）"
  fi
  LOCAL_DELETE+=("$br")
done < <(git for-each-ref --merged "$BASE_REF" --format='%(refname:lstrip=2)' refs/heads)
echo ""

# ---- 3) リモートブランチ（--remote 指定時のみ・open PR なしの裏取り付き） ----
echo "## リモートブランチ（マージ済み）"
REMOTE_DELETE=()
REMOTE_SHA=()
while IFS= read -r ref; do
  # origin/HEAD は基準ブランチを指す別名でブランチではない（%(refname:short) では "origin" と表示される）
  [ "$ref" = origin/HEAD ] && continue
  br=${ref#origin/}
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue # リモートの保護ブランチ
  # fetch に失敗したら、古い情報のままリモートを消さない
  if ! $FETCH_OK; then
    echo "- SKIP (fetch に失敗したので消さない): origin/$br"
    continue
  fi
  if too_young "refs/remotes/$ref"; then
    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): origin/$br"
    continue
  fi
  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/remotes/$ref"; then
    echo "- KEEP (no own commits, first fetched $CREATED, < $MIN_AGE_DAYS days or unknown): origin/$br"
    continue
  fi
  if $ON_CHAIN && observed_young "refs/remotes/$ref"; then
    echo "- KEEP (no own commits, first seen in $BASE $ENTERED, < $MIN_AGE_DAYS days or unknown): origin/$br"
    continue
  fi
  # 残す worktree で checkout 中のブランチは、リモートも消さない（その worktree の upstream を奪わない）
  if kept_checkout "$br"; then
    echo "- SKIP (残す worktree で checkout 中): origin/$br"
    continue
  fi
  # 裏取り: open PR が無いこと。gh で確かめられなければ消さない（open PR のブランチを消すと PR が閉じる）
  open=$(gh pr list ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --head "$br" --state open \
    --json number -q length 2>/dev/null) || open=""
  # origin が fork なら、祖先のリポジトリに出した PR も数える
  if [ "$open" = 0 ]; then
    if ! $GH_PARENTS_OK; then
      open=""
    else
      for p in ${GH_PARENTS[@]+"${GH_PARENTS[@]}"}; do
        n=$(gh pr list -R "$p" --head "$br" --state open --json number -q length 2>/dev/null) || n=""
        [ "$n" = 0 ] && continue
        open=$n
        break
      done
    fi
  fi
  case "$open" in
    0) ;;
    '' | *[!0-9]*)
      echo "- SKIP (open PR の有無を確かめられない): origin/$br"
      continue ;;
    *)
      echo "- SKIP (open PRあり): origin/$br"
      continue ;;
  esac
  # このブランチを base にする open PR（stacked PR）があれば消さない（base を消すとその PR は閉じる）。
  # 確かめられなければ消さない
  stacked=$(gh pr list ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --base "$br" --state open \
    --json number -q length 2>/dev/null) || stacked=""
  case "$stacked" in
    0) ;;
    '' | *[!0-9]*)
      echo "- SKIP (このブランチを base にする open PR の有無を確かめられない): origin/$br"
      continue ;;
    *)
      echo "- SKIP (このブランチを base にする open PR あり): origin/$br"
      continue ;;
  esac
  REMOTE_DELETE+=("$br")
  REMOTE_SHA+=("$(git rev-parse "refs/remotes/$ref")")
  echo "- 削除候補: origin/${br}（${ENTERED}、open PR なし）$($REMOTE || echo ' ※--remote未指定のため実行対象外')"
done < <(git for-each-ref --merged "$BASE_REF" --format='%(refname:lstrip=2)' refs/remotes/origin)
echo ""

# ---- 4) 実行 ----
# still_checked_out <ブランチ名>: 今（計画ではなく実行の時点で）どれかの worktree で checkout 中なら 0
still_checked_out() {
  git worktree list --porcelain | grep -qxF -- "branch refs/heads/$1"
}
apply_worktrees() {
  local wt err why ignored
  for wt in ${WT_REMOVE[@]+"${WT_REMOVE[@]}"}; do
    # 計画から削除までの間（gh の問い合わせで数秒ある）に生まれた作業を失わないよう、消す直前に確かめ直す
    if why=$(hidden_work "$wt"); then
      echo "- SKIP (計画の後に変わった: ${why}): $wt"
      continue
    fi
    if ! ignored=$(unregenerable_ignored "$wt") || [ -n "$ignored" ]; then
      echo "- SKIP (計画の後に変わった: ignore されたファイル $(printf '%s\n' "$ignored" | head -3 | tr '\n' ' ')): $wt"
      continue
    fi
    if err=$(git worktree remove "$wt" 2>&1); then
      echo "- REMOVED: $wt"
    else
      echo "- FAILED remove: $wt — $(reason "$err")"
    fi
  done
}
apply_remote() {
  local i br err
  $REMOTE || return 0
  for i in ${REMOTE_DELETE[@]+"${!REMOTE_DELETE[@]}"}; do
    br=${REMOTE_DELETE[$i]}
    # 消せなかった・残した worktree でまだ checkout 中なら、リモートも消さない
    if still_checked_out "$br"; then
      echo "- SKIP (worktree でまだ checkout 中): origin/$br"
      continue
    fi
    # fetch したときの先端から動いていたら消さない（その後に push されたコミットを失わない）。消す ref は
    # refs/heads/ で指定する（短い名前だと、ブランチが先に消えていれば同じ名前のタグを消し、両方あれば拒否される）
    if err=$(git push --force-with-lease="refs/heads/$br:${REMOTE_SHA[$i]}" origin ":refs/heads/$br" 2>&1); then
      echo "- DELETED: origin/$br"
    else
      echo "- FAILED: origin/$br — $(reason "$err")"
    fi
  done
}
apply_local() {
  local br err
  for br in ${LOCAL_DELETE[@]+"${LOCAL_DELETE[@]}"}; do
    if still_checked_out "$br"; then
      echo "- SKIP (worktree でまだ checkout 中): $br"
      continue
    fi
    if err=$(git branch -d "$br" 2>&1); then
      echo "- DELETED: $br"
    else
      echo "- FAILED (-d拒否): $br — $(reason "$err")"
    fi
  done
}
if $APPLY; then
  echo "## 実行"
  # 消す worktree の中から git を動かさないよう、main worktree から実行する
  cd "$MAIN_WT" || exit 1
  # リモートをローカルより先に消す。upstream が残っていると、基準ブランチに入っていても
  # upstream より先に進んだローカルブランチを git branch -d が拒否する
  for step in worktrees remote local; do
    "apply_$step"
  done
  echo ""
fi

$APPLY || cat <<'EOT'
---
これは DRY-RUN です。実行するには内容を確認のうえ:
  bash ~/.claude/scripts/repo-janitor.sh <repo> --apply           # ローカルのみ
  bash ~/.claude/scripts/repo-janitor.sh <repo> --apply --remote  # リモート込み（リモートを先に消す）
EOT
