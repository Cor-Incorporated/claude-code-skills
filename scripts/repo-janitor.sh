#!/usr/bin/env bash
# repo-janitor.sh — worktree/ブランチの安全な掃除。デフォルトは dry-run（計画表示のみ）
# 使い方:
#   repo-janitor.sh <repoパス>            # dry-run: 削除候補の一覧と理由を表示するだけ
#   repo-janitor.sh <repoパス> --apply    # ローカルの削除を実行（マージ済みのみ、-d 安全削除）
#   repo-janitor.sh <repoパス> --apply --remote  # マージ済みリモートブランチも削除
# 安全装置:
#   - 保護ブランチ (main/master/develop/stg) は絶対に触らない
#   - 未マージブランチは削除しない（git branch -d のみ、-D は使わない）
#   - dirty な worktree はスキップして警告
#   - 現在checkout中のブランチ/worktreeは触らない
set -uo pipefail

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
cd "$REPO"
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# 統合ブランチの決定 (develop 優先)
if git show-ref --verify --quiet refs/remotes/origin/develop; then BASE=origin/develop
elif git show-ref --verify --quiet refs/remotes/origin/main; then BASE=origin/main
else BASE=origin/master; fi

git fetch --prune origin >/dev/null 2>&1 || echo "WARN: fetch失敗（オフライン?）。ローカル情報のみで判定します。"

MODE="DRY-RUN（計画のみ・変更なし）"; $APPLY && MODE="APPLY（削除実行）"
echo "# repo-janitor: $(basename "$REPO_ROOT") — $MODE"
echo "基準ブランチ: $BASE"
echo ""

CURRENT=$(git branch --show-current)

# ---- 1) worktree ----
echo "## Worktrees"
git worktree prune 2>/dev/null || true
MAIN_WT=$(git worktree list --porcelain | head -1 | awk '{print $2}')
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
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
    if $APPLY; then
      git worktree remove "$wt" 2>/dev/null && echo "- REMOVED: $wt [$br] (merged into $BASE)" \
        || echo "- FAILED remove: $wt [$br]"
    else
      echo "- 削除候補: $wt [$br] — $BASE にマージ済み・clean"
    fi
  else
    echo "- KEEP (unmerged): $wt [$br]"
  fi
done
echo ""

# ---- 2) ローカルブランチ（マージ済みのみ） ----
echo "## ローカルブランチ（$BASE にマージ済み）"
git branch --merged "$BASE" --format='%(refname:short)' | while read -r br; do
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue
  [ "$br" = "$CURRENT" ] && { echo "- SKIP (current): $br"; continue; }
  # worktreeでcheckout中のブランチはスキップ
  if git worktree list --porcelain | grep -q "branch refs/heads/$br\$"; then
    echo "- SKIP (checked out in worktree): $br"
    continue
  fi
  if $APPLY; then
    git branch -d "$br" >/dev/null 2>&1 && echo "- DELETED: $br" || echo "- FAILED (-d拒否=未マージ扱い): $br"
  else
    echo "- 削除候補: $br"
  fi
done
echo ""

# ---- 3) リモートブランチ（--remote 指定時のみ・PR merged 裏取り付き） ----
echo "## リモートブランチ（マージ済み）"
git branch -r --merged "$BASE" --format='%(refname:short)' | sed 's|^origin/||' | while read -r br; do
  [ -z "$br" ] && continue
  echo "$br" | grep -Eq "$PROTECTED" && continue
  [ "$br" = "HEAD" ] && continue
  # 裏取り: このブランチのPRがmergedであること（open PRがあれば絶対スキップ）
  state=$(gh pr list --head "$br" --state all --limit 1 --json state -q '.[0].state' 2>/dev/null || echo "")
  if [ "$state" = "OPEN" ]; then
    echo "- SKIP (open PRあり): origin/$br"
    continue
  fi
  if $APPLY && $REMOTE; then
    git push origin --delete "$br" >/dev/null 2>&1 && echo "- DELETED: origin/$br" || echo "- FAILED: origin/$br"
  else
    echo "- 削除候補: origin/${br}（PR state: ${state:-不明}）$($REMOTE || echo ' ※--remote未指定のため実行対象外')"
  fi
done
echo ""

$APPLY || cat <<'EOT'
---
これは DRY-RUN です。実行するには内容を確認のうえ:
  bash ~/.claude/scripts/repo-janitor.sh <repo> --apply           # ローカルのみ
  bash ~/.claude/scripts/repo-janitor.sh <repo> --apply --remote  # リモート込み
EOT
