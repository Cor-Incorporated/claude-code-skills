#!/usr/bin/env bash
# T9-3 + T10-1: リポ横断の C11 着地計数（正本計数器）
#
# C11 着地数は**本計数器の出力のみを正**とする（監督も手元コマンドを使わない —
# design/ops/c11-counter-ssot.md 参照）。集合は引数で明示し、既定値を隠さない。
#
# 引数:
#   --scope=all       全 Cor-Incorporated リポ（既定）
#   --scope=active90  ~/Developer 直下かつ直近 90 日に commit があるリポのみ
#   --branch=default  デフォルトブランチのみ（既定）
#   --branch=any      main / develop / dev のいずれかで着地していれば 1
#   --legacy-lowercase-only  旧測定器の挙動（小文字のみ）を再現（red 実測用）
#
# 既定: --scope=all --branch=default（両対応）。既定値は出力に常に表示する。
#
# 判定: .github/pull_request_template.md または .github/PULL_REQUEST_TEMPLATE.md に
#       「実環境貫通」が 1 以上あるか（大文字小文字両対応）
set -uo pipefail

SCOPE="all"
BRANCH="default"
LEGACY=0
for a in "$@"; do
  case "$a" in
    --scope=all) SCOPE="all" ;;
    --scope=active90) SCOPE="active90" ;;
    --branch=default) BRANCH="default" ;;
    --branch=any) BRANCH="any" ;;
    --legacy-lowercase-only) LEGACY=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# active90: ~/Developer 直下かつ直近 90 日 commit あり
active90() {
  local repo="$1" d out
  d="$HOME/Developer/$repo"
  [[ -d "$d/.git" ]] || return 1
  # git log はマッチなしでも exit 0 を返す — 出力の有無で判定する（T11-1 で発見）
  out=$(git -C "$d" log -1 --format=%ct --since="90 days ago" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  return 0
}

count=0
declare -a HITS=()
for repo in $(gh repo list Cor-Incorporated --limit 100 --json name --jq '.[].name' 2>/dev/null); do
  [[ "$SCOPE" == "active90" ]] && ! active90 "$repo" && continue

  if [[ "$BRANCH" == "default" ]]; then
    branches=("$(gh api "repos/Cor-Incorporated/$repo" --jq '.default_branch' 2>/dev/null || true)")
    [[ -z "${branches[0]}" ]] && continue
  else
    branches=("main" "develop" "dev")
  fi

  if [[ "$LEGACY" -eq 1 ]]; then
    tmpls=("pull_request_template.md")
  else
    tmpls=("pull_request_template.md" "PULL_REQUEST_TEMPLATE.md")
  fi

  for br in "${branches[@]}"; do
    for tmpl in "${tmpls[@]}"; do
      hit=$(gh api "repos/Cor-Incorporated/$repo/contents/.github/$tmpl?ref=$br" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -c "実環境貫通")
      if [[ "$hit" -ge 1 ]] 2>/dev/null; then
        HITS+=("$repo/$br/$tmpl")
        count=$((count + 1))
        break 2
      fi
    done
  done
done

if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  printf '%s\n' "${HITS[@]}"
fi
echo "C11_landed=$count scope=$SCOPE branch=$BRANCH case=$([ "$LEGACY" -eq 1 ] && echo lowercase-only || echo both-cases)"
