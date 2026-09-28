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
#   - dirty な worktree はスキップして警告
#   - 現在checkout中のブランチ、渡されたパスの worktree、呼び出し元がいる worktree は触らない
#   - open PR の有無を gh で確かめられないリモートブランチは消さない。消すときは、fetch した
#     ときの先端から動いていないことを --force-with-lease で確かめる
#   - --apply --remote ではリモートを先に消す（upstream が残っていると git branch -d が拒否する）
# dry-run も git fetch --prune で origin の追跡ブランチを更新する。--apply は計画を作り直すので、
# 承認した dry-run の直後に実行する（日付をまたぐと 7 日を越えた分が候補に加わりうる）
set -uo pipefail
# 呼び出し元の git 環境（hook の中など）を引き継ぐと、渡したパスではなく別のリポジトリを掃除してしまう
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

MIN_AGE_DAYS=7

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

# 統合ブランチの決定 (develop 優先)
if git show-ref --verify --quiet refs/remotes/origin/develop; then BASE=origin/develop
elif git show-ref --verify --quiet refs/remotes/origin/main; then BASE=origin/main
else BASE=origin/master; fi
BASE_NAME=${BASE#origin/}

git fetch --prune origin >/dev/null 2>&1 || echo "WARN: fetch失敗（オフライン?）。ローカル情報のみで判定します。"

# gh は upstream remote を origin より優先して別のリポジトリの PR を見ることがあるので、origin を明示する
GH_REPO_ARGS=()
origin_slug=$(git remote get-url origin 2>/dev/null \
  | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
[ -n "$origin_slug" ] && GH_REPO_ARGS=(-R "$origin_slug")

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
while IFS= read -r c; do FP+=("$c"); done < <(git rev-list --first-parent --reverse "$BASE" 2>/dev/null)

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
$APPLY && { git worktree prune 2>/dev/null || true; }
MAIN_WT=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)
WT_REMOVE=()  # 消す worktree
WT_FREED=()   # それを消すと checkout が外れるブランチ
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
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty" -gt 0 ]; then
    echo "- SKIP (dirty ${dirty}files): $wt [$br]"
    continue
  fi
  if echo "$br" | grep -Eq "$PROTECTED"; then
    echo "- SKIP (protected): $wt [$br]"
    continue
  fi
  if [ -n "$br" ] && git merge-base --is-ancestor "refs/heads/$br" "$BASE" 2>/dev/null; then
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
    WT_REMOVE+=("$wt")
    WT_FREED+=("$br")
    echo "- 削除候補: $wt [$br] — $BASE にマージ済み（${ENTERED}）・clean"
  else
    echo "- KEEP (unmerged): $wt [$br]"
  fi
done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
echo ""

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
  # worktree で checkout 中のブランチは、その worktree を消すときだけ候補にする
  if git worktree list --porcelain | grep -qxF "branch refs/heads/$br"; then
    if ! in_list "$br" ${WT_FREED[@]+"${WT_FREED[@]}"}; then
      echo "- SKIP (checked out in worktree): $br"
      continue
    fi
    echo "- 削除候補: ${br}（${ENTERED}、worktree と一緒に）"
  else
    echo "- 削除候補: ${br}（${ENTERED}）"
  fi
  LOCAL_DELETE+=("$br")
done < <(git for-each-ref --merged "$BASE" --format='%(refname:lstrip=2)' refs/heads)
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
  if too_young "refs/remotes/$ref"; then
    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): origin/$br"
    continue
  fi
  if $ON_CHAIN && created_recently "$REPO_ROOT" "refs/remotes/$ref"; then
    echo "- KEEP (no own commits, first fetched $CREATED, < $MIN_AGE_DAYS days or unknown): origin/$br"
    continue
  fi
  # 裏取り: open PR が無いこと。gh で確かめられなければ消さない（open PR のブランチを消すと PR が閉じる）
  open=$(gh pr list ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --head "$br" --state open \
    --json number -q length 2>/dev/null) || open=""
  case "$open" in
    0) ;;
    '' | *[!0-9]*)
      echo "- SKIP (open PR の有無を確かめられない): origin/$br"
      continue ;;
    *)
      echo "- SKIP (open PRあり): origin/$br"
      continue ;;
  esac
  REMOTE_DELETE+=("$br")
  REMOTE_SHA+=("$(git rev-parse "refs/remotes/$ref")")
  echo "- 削除候補: origin/${br}（${ENTERED}、open PR なし）$($REMOTE || echo ' ※--remote未指定のため実行対象外')"
done < <(git for-each-ref --merged "$BASE" --format='%(refname:lstrip=2)' refs/remotes/origin)
echo ""

# ---- 4) 実行 ----
apply_worktrees() {
  local wt err
  for wt in ${WT_REMOVE[@]+"${WT_REMOVE[@]}"}; do
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
    # fetch したときの先端から動いていたら消さない（その後に push されたコミットを失わない）
    if err=$(git push --force-with-lease="refs/heads/$br:${REMOTE_SHA[$i]}" origin --delete "$br" 2>&1); then
      echo "- DELETED: origin/$br"
    else
      echo "- FAILED: origin/$br — $(reason "$err")"
    fi
  done
}
apply_local() {
  local br err
  for br in ${LOCAL_DELETE[@]+"${LOCAL_DELETE[@]}"}; do
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
