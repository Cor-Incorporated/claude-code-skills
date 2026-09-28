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
# <repo>/.worktrees/<agent>/<slug>/ の中でも、main checkout と同じ深さ（4）まで探す
MAX_DEPTH=7
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

CACHE_NAMES=(node_modules .venv venv __pycache__ .next .mypy_cache .ruff_cache .pytest_cache target)
# git status の未追跡の行のうち成果物のものは「未コミットの作業」に数えない（.gitignore して
# いないリポジトリのため）。追跡中のファイルの変更は、成果物の名前の下にあっても作業に数える
UNTRACKED_CACHE_RE='^\?\? (.*/)?(node_modules|\.venv|venv|__pycache__|\.next|\.mypy_cache|\.ruff_cache|\.pytest_cache|target)(/|$)'
today_epoch=$(date +%s)

# 判定はリポジトリ群（main checkout と linked worktree。git の共通ディレクトリで束ねる）の単位で
# 行い、結果を覚えておく（worktree の多いリポジトリで git status を何度も走らせないため）
family_memo=""

is_stale() { # $1=dir $2=days → 0 if last commit older than days
  local d="$1" days="$2" common key hit last rc wt st work
  [ -e "$d/.git" ] || return 0  # git管理外は stale 扱い（.git がファイルの linked worktree は git 管理）
  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  key="$common|$days"
  hit=$(printf '%s' "$family_memo" | awk -F'\t' -v k="$key" '$1 == k {print $2; exit}')
  [ -n "$hit" ] && return "$hit"
  rc=1
  # 全 ref と全 worktree の HEAD のうち最新のコミットで測る。コミットが無い・読めない
  # リポジトリは古さが分からないので stale にしない
  last=$(git -C "$d" log -1 --all --format=%ct 2>/dev/null) || last=""
  if [ -n "$last" ] && [ $(( (today_epoch - last) / 86400 )) -ge "$days" ]; then
    rc=0
    # 未コミットの作業がある worktree が 1 つでもあれば使用中。grep -q は pipefail の下で
    # 上流の SIGPIPE が失敗扱いになるので、変数に受けてから調べる。
    # 既知の制限: .git/worktrees を読めないと git worktree list が一部の worktree を黙って落とす
    # ことがあり、その worktree の未コミットの作業は見えない（その場合に消えうるのは、再生成
    # できる成果物だけ。追跡中のファイルを含む成果物は下の sweep が消さない）
    while IFS= read -r wt; do
      [ -d "$wt" ] || continue  # 消えた worktree（prunable）は作業を持てない
      # 未追跡のディレクトリは畳まれて表示される（packages/ など）ので、ファイル単位に展開して見る。
      # 状態を読めない worktree（index の破損など）は作業の有無が分からないので使用中とみなす
      if ! st=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null); then rc=1; break; fi
      work=$(printf '%s\n' "$st" | grep -v '^$' | grep -Ev "$UNTRACKED_CACHE_RE" || true)
      if [ -n "$work" ]; then rc=1; break; fi
    done < <(git -C "$d" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  fi
  family_memo="$family_memo$key"$'\t'"$rc"$'\n'
  return "$rc"
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

prune_args=()
for n in "${CACHE_NAMES[@]}"; do prune_args+=(-name "$n" -o); done
unset 'prune_args[${#prune_args[@]}-1]'

# archivable <プロジェクト> <日数>: プロジェクトが古く、中にあるリポジトリもすべて古いときだけ 0。
# git 管理外のフォルダでも、中に使用中のリポジトリがあれば _archive へ移す提案はしない。
# 名前だけで成果物と決められない target/・venv/・.venv/ の中も探す
archivable() {
  local g
  is_stale "$1" "$2" || return 1
  while IFS= read -r -d '' g; do
    is_stale "$(dirname "$g")" "$2" || return 1
  done < <(find "$1" -mindepth 2 -maxdepth "$MAX_DEPTH" \
    \( -type d \( -name node_modules -o -name __pycache__ -o -name .next -o -name .mypy_cache \
    -o -name .ruff_cache -o -name .pytest_cache \) -prune \) -o \( -name .git -print0 -prune \) 2>/dev/null)
  return 0
}

# sweep <探す場所> <残りの深さ> <プロジェクト>: 成果物を探し、それを含むリポジトリ群が
# 古いものだけ数える（--apply なら消す）。成果物ではない target/・venv/ の中も探す
sweep() {
  local start="$1" depth="$2" project="$3" t rel root mb tracked
  [ "$depth" -ge 1 ] || return 0
  while IFS= read -r -d '' t; do
    if ! looks_like_cache "$t"; then
      rel=${t#"$start"/}
      sweep "$t" $((depth - $(printf '%s\n' "$rel" | awk -F/ '{print NF}'))) "$project"
      continue
    fi
    # 入れ子のリポジトリ（worktree・別の clone）の成果物は、そのリポジトリ群の古さで判定する
    root=$(owning_root "$t" "$project")
    is_stale "$root" "$STALE_DAYS" || continue
    # 追跡中のファイルを含む成果物は消さない（コミット済みの node_modules/ など。消すと作業ツリー
    # から追跡中のファイルが消える）。調べられなければ消さない側に倒す
    if [ -e "$root/.git" ]; then
      tracked=$(git -C "$root" ls-files -- "${t#"$root"/}" 2>/dev/null) || continue
      [ -z "$tracked" ] || continue
    fi
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
  done < <(find "$start" -mindepth 1 -maxdepth "$depth" \
    \( -name .git -prune -o -type d \( "${prune_args[@]}" \) -prune -print0 \) 2>/dev/null)
}

echo "=== dev-cleanup dry-run=$([ "$APPLY" = true ] && echo NO || echo YES) ($(date +%F)) ==="
total_mb=0
failed=0
for dir in "$DEV_DIR"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  case "$name" in _archive|_repo-backups|_sandbox) continue ;; esac

  # 使用中のプロジェクトの中にある古い入れ子のリポジトリも見るため、全プロジェクトを探す
  sweep "$dir" "$MAX_DEPTH" "$dir"

  if archivable "$dir" "$ARCHIVE_DAYS"; then
    echo "ARCHIVE候補 (${ARCHIVE_DAYS}日+ コミットなし): $name → mv '$dir' '$DEV_DIR/_archive/'"
  fi
done
echo "=== 回収可能/回収済み合計: ${total_mb} MB ==="
[ "$APPLY" = true ] || echo "実削除するには: bash $0 --apply"
if [ "$failed" -gt 0 ]; then
  echo "削除できなかった成果物: ${failed} 件（上の WARN を参照）" >&2
  exit 1
fi
