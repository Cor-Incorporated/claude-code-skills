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
#   - 未マージブランチは削除しない（git branch -d のみ、-D は使わない）
#   - dirty な worktree はスキップして警告
#   - 現在checkout中のブランチ/worktreeは触らない
#   - --apply --remote ではリモートを先に消す（upstream が残っていると git branch -d が拒否する）
set -uo pipefail

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
# cd に失敗したまま進むと、今いるディレクトリのリポジトリを掃除してしまう
cd "$REPO" || { echo "ERROR: $REPO へ移動できない" >&2; exit 1; }
REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: $REPO は git リポジトリではない" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

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

# 基準ブランチの first-parent を古い順に並べる（bash 3.2 には mapfile が無い）
NOW=$(date +%s)
FP=()
while IFS= read -r c; do FP+=("$c"); done < <(git rev-list --first-parent --reverse "$BASE" 2>/dev/null)

# too_young <commit>: 基準ブランチに入ってから MIN_AGE_DAYS 日未満なら 0 を返し、ENTERED に入った日を入れる。
# 入った日 = first-parent を二分探索して、commit を含む最初のコミットの日付。
# `git log --first-parent --ancestry-path <commit>..<base> | tail -1` は、commit 自身が
# first-parent 上にあると次のコミットの日付を返す（1 つずれる）ので使わない。
# 判定できないときは若い側（消さない側）に倒す
ENTERED="?"
too_young() {
  local lo=0 hi mid ts
  ENTERED="?"
  hi=$(( ${#FP[@]} - 1 ))
  [ "$hi" -ge 0 ] || return 0
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    if git merge-base --is-ancestor "$1" "${FP[$mid]}" 2>/dev/null; then hi=$mid; else lo=$((mid + 1)); fi
  done
  git merge-base --is-ancestor "$1" "${FP[$lo]}" 2>/dev/null || return 0
  read -r ts ENTERED < <(git log -1 --format='%ct %cs' "${FP[$lo]}")
  [ $(( NOW - ts )) -lt $(( MIN_AGE_DAYS * 86400 )) ]
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
git worktree prune 2>/dev/null || true
MAIN_WT=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)
WT_REMOVE=()  # 消す worktree
WT_FREED=()   # それを消すと checkout が外れるブランチ
while IFS= read -r wt; do
  [ "$wt" = "$MAIN_WT" ] && continue
  br=$(git -C "$wt" branch --show-current 2>/dev/null || echo "?")
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty" -gt 0 ]; then
    echo "- SKIP (dirty ${dirty}files): $wt [$br]"
    continue
  fi
  if echo "$br" | grep -Eq "$PROTECTED"; then
    echo "- SKIP (protected): $wt [$br]"
    continue
  fi
  if [ -n "$br" ] && git merge-base --is-ancestor "$br" "$BASE" 2>/dev/null; then
    if too_young "$br"; then
      echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $wt [$br]"
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
echo "## ローカルブランチ（$BASE にマージ済み）"
LOCAL_DELETE=()
while IFS= read -r br; do
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue
  [ "$br" = "$CURRENT" ] && { echo "- SKIP (current): $br"; continue; }
  if too_young "$br"; then
    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): $br"
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
done < <(git branch --merged "$BASE" --format='%(refname:short)')
echo ""

# ---- 3) リモートブランチ（--remote 指定時のみ・PR merged 裏取り付き） ----
echo "## リモートブランチ（マージ済み）"
REMOTE_DELETE=()
while IFS= read -r ref; do
  # origin/HEAD は基準ブランチを指す別名でブランチではない（%(refname:short) では "origin" と表示される）
  [ "$ref" = origin/HEAD ] && continue
  br=${ref#origin/}
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue
  if too_young "refs/remotes/$ref"; then
    echo "- KEEP (entered $BASE_NAME $ENTERED, < $MIN_AGE_DAYS days): origin/$br"
    continue
  fi
  # 裏取り: このブランチのPRがmergedであること（open PRがあれば絶対スキップ）
  state=$(gh pr list ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --head "$br" --state all --limit 1 \
    --json state -q '.[0].state' 2>/dev/null || echo "")
  if [ "$state" = "OPEN" ]; then
    echo "- SKIP (open PRあり): origin/$br"
    continue
  fi
  REMOTE_DELETE+=("$br")
  echo "- 削除候補: origin/${br}（${ENTERED}、PR state: ${state:-不明}）$($REMOTE || echo ' ※--remote未指定のため実行対象外')"
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
  local br err
  $REMOTE || return 0
  for br in ${REMOTE_DELETE[@]+"${REMOTE_DELETE[@]}"}; do
    if err=$(git push origin --delete "$br" 2>&1); then
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
