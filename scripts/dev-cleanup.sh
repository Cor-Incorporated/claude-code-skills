#!/usr/bin/env bash
# dev-cleanup.sh — ~/Developer の定期クリーンアップ (2026-07-06 大整理の再発防止)
#
# 機能:
#   1. 90日以上コミットのないプロジェクトの node_modules/venv/ビルド成果物を検出
#   2. _archive/ 移動候補（180日以上コミットなし）を提示
#   3. デフォルトは dry-run。--apply で実削除（成果物のみ。フォルダ移動は提案のみ）
#
# 使い方:
#   bash dev-cleanup.sh            # dry-run（レポートのみ）
#   bash dev-cleanup.sh --apply    # 成果物を実削除
set -euo pipefail

DEV_DIR="${DEV_DIR:-$HOME/Developer}"
STALE_DAYS=90
ARCHIVE_DAYS=180
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

CACHE_NAMES=(node_modules .venv venv __pycache__ .next .mypy_cache .ruff_cache .pytest_cache target)
today_epoch=$(date +%s)

is_stale() { # $1=dir $2=days → 0 if last commit older than days
  local d="$1" days="$2" last epoch
  [ -d "$d/.git" ] || return 0  # git管理外は stale 扱い
  last=$(git -C "$d" log -1 --format=%ct 2>/dev/null) || return 0
  epoch=$(( (today_epoch - last) / 86400 ))
  [ "$epoch" -ge "$days" ]
}

echo "=== dev-cleanup dry-run=$([ "$APPLY" = true ] && echo NO || echo YES) ($(date +%F)) ==="
total_mb=0
for dir in "$DEV_DIR"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  case "$name" in _archive|_repo-backups|_sandbox) continue ;; esac

  if is_stale "$dir" "$STALE_DAYS"; then
    prune_args=()
    for n in "${CACHE_NAMES[@]}"; do prune_args+=(-name "$n" -o); done
    unset 'prune_args[${#prune_args[@]}-1]'
    while IFS= read -r -d '' t; do
      mb=$(du -sm "$t" 2>/dev/null | awk '{print $1}')
      [ "${mb:-0}" -lt 10 ] && continue
      total_mb=$((total_mb + mb))
      if [ "$APPLY" = true ]; then
        rm -rf "$t" && echo "DELETED ${mb}MB: $t"
      else
        echo "candidate ${mb}MB: $t"
      fi
    done < <(find "$dir" -maxdepth 4 -type d \( "${prune_args[@]}" \) -prune -print0 2>/dev/null)
  fi

  if is_stale "$dir" "$ARCHIVE_DAYS"; then
    echo "ARCHIVE候補 (${ARCHIVE_DAYS}日+ コミットなし): $name → mv '$dir' '$DEV_DIR/_archive/'"
  fi
done
echo "=== 回収可能/回収済み合計: ${total_mb} MB ==="
[ "$APPLY" = true ] || echo "実削除するには: bash $0 --apply"
