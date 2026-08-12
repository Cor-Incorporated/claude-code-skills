#!/usr/bin/env bash
# T9-3: リポ横断の C11 着地計数（PR テンプレの大文字小文字**両対応**）
#
# 監督の測定器（旧）は .github/pull_request_template.md（小文字）しか見ず、
# persona-village-v2 の大文字 PULL_REQUEST_TEMPLATE.md を数え落としていた。
# 本計測器は両ファイル名を確認する。--legacy-lowercase-only で旧挙動を再現できる。
#
# 対象: Cor-Incorporated org のリポ × デフォルトブランチ
# 判定: .github/pull_request_template.md または .github/PULL_REQUEST_TEMPLATE.md に
#       「実環境貫通」が 1 以上あるか
set -uo pipefail

LEGACY=0
[[ "${1:-}" == "--legacy-lowercase-only" ]] && LEGACY=1

count=0
declare -a HITS=()
for repo in $(gh repo list Cor-Incorporated --limit 100 --json name --jq '.[].name' 2>/dev/null); do
  br=$(gh api "repos/Cor-Incorporated/$repo" --jq '.default_branch' 2>/dev/null) || continue
  if [[ "$LEGACY" -eq 1 ]]; then
    tmpls=("pull_request_template.md")
  else
    tmpls=("pull_request_template.md" "PULL_REQUEST_TEMPLATE.md")
  fi
  for tmpl in "${tmpls[@]}"; do
    hit=$(gh api "repos/Cor-Incorporated/$repo/contents/.github/$tmpl?ref=$br" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -c "実環境貫通")
    if [[ "$hit" -ge 1 ]] 2>/dev/null; then
      HITS+=("$repo/$br/$tmpl")
      count=$((count + 1))
      break
    fi
  done
done

if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  printf '%s\n' "${HITS[@]}"
fi
echo "C11_default_branch_landed=$count (mode=$([ "$LEGACY" -eq 1 ] && echo legacy-lowercase-only || echo both-cases))"
