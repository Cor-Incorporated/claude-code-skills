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
  [ -e "$d/.git" ] || return 0  # git管理外は stale 扱い（.git がファイルの linked worktree は git 管理）
  # 全 ref と全 worktree の HEAD のうち最新のコミットで測る。HEAD だけで測ると、古い
  # リポジトリの中で作業中の worktree（<repo>/.worktrees/<agent>/<slug>）まで古い扱いになる
  last=$(git -C "$d" log -1 --all --format=%ct 2>/dev/null) || return 1
  # コミットが無い・読めないリポジトリは古さが分からないので stale にしない
  [ -n "$last" ] || return 1
  epoch=$(( (today_epoch - last) / 86400 ))
  [ "$epoch" -ge "$days" ]
}

# $1=成果物 $2=プロジェクト → 成果物を含む最も内側の git リポジトリ（無ければプロジェクト）
owning_root() {
  local p
  p=$(dirname "$1")
  while [ "$p" != "$2" ] && [ "$p" != / ]; do
    [ -e "$p/.git" ] && { printf '%s\n' "$p"; return; }
    p=$(dirname "$p")
  done
  printf '%s\n' "$2"
}

# target と venv は名前だけで決めない（同名のデータのディレクトリを消さないため）
looks_like_cache() {
  case "$(basename "$1")" in
    target) [ -e "$(dirname "$1")/Cargo.toml" ] || [ -e "$(dirname "$1")/pom.xml" ] ;;
    venv|.venv) [ -e "$1/pyvenv.cfg" ] ;;
    *) return 0 ;;
  esac
}

echo "=== dev-cleanup dry-run=$([ "$APPLY" = true ] && echo NO || echo YES) ($(date +%F)) ==="
total_mb=0
failed=0
for dir in "$DEV_DIR"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  case "$name" in _archive|_repo-backups|_sandbox) continue ;; esac

  if is_stale "$dir" "$STALE_DAYS"; then
    prune_args=()
    for n in "${CACHE_NAMES[@]}"; do prune_args+=(-name "$n" -o); done
    unset 'prune_args[${#prune_args[@]}-1]'
    while IFS= read -r -d '' t; do
      looks_like_cache "$t" || continue
      # 入れ子のリポジトリ（worktree・別の clone）の成果物は、そのリポジトリ自身の古さで判定する
      root=$(owning_root "$t" "$dir")
      [ "$root" = "$dir" ] || is_stale "$root" "$STALE_DAYS" || continue
      # 読めないファイルがあっても掃除を止めない（pipefail で代入ごと落ちないようにする）
      mb=$( { du -sm "$t" 2>/dev/null || true; } | awk 'NR==1 {print $1}')
      if [ -z "$mb" ]; then
        echo "WARN: サイズを読めないので飛ばす: $t" >&2
        continue
      fi
      [ "$mb" -lt 10 ] && continue
      if [ "$APPLY" = true ]; then
        if rm -rf "$t"; then
          total_mb=$((total_mb + mb))
          echo "DELETED ${mb}MB: $t"
        else
          failed=$((failed + 1))
          echo "WARN: 削除できなかった: $t" >&2
        fi
      else
        total_mb=$((total_mb + mb))
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
if [ "$failed" -gt 0 ]; then
  echo "削除できなかった成果物: ${failed} 件（上の WARN を参照）" >&2
  exit 1
fi
