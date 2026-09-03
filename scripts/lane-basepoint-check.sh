#!/usr/bin/env bash
# 並列レーンの基点検査 — 発射直前ゲート + 重複実装の先回り検出.
#
# Issue: Cor-Incorporated/aidd-governance#91
# Spec : design/harness-spec.md "### H11."（撤収リマインダ）の追補。P4 / P9 追補。
#
# 起点事故 (2026-08-26〜27, Grift Phase B):
#   監督は 4 Issue を既存 worktree へ割り当てて同時に起動した。worktree の
#   基点は数時間前の develop のままで、その間に別レーンの成果が develop へ
#   入っていた。feat/l-s6-api は develop に既にある 4 ファイルを独立に再実装し、
#   マージ時に add/add 競合 4 件。delivery_incident_judgment_store.go は
#   develop 650 行 対 ブランチ 290 行で、成熟度から develop 側を採用したため
#   ブランチ側の実装はまるごと破棄された。
#
#   worktree は「作った時の基点」を保持し、再利用しても更新されない。
#   長時間セッションで使い回すと基点は静かに古くなる。
#   検出点がマージ時しかなかったことが損失を確定させた。
#
# --- この装置が実際に判定するもの（過大主張しない） ---------------------------
#   basepoint  : HEAD が base より何 commit 遅れているか。これは git の実測値
#                であり、真値である。
#   duplicates : このブランチが **新規作成** したファイル (--diff-filter=A) と
#                同名のファイルが base に既に存在するか。これは add/add 競合の
#                必要条件であって十分条件ではない。逆に「同名ではないが同じ
#                責務を再実装した」重複は検出できない。名前が違う重複実装は
#                この装置の対象外であり、それを主張してはならない。
#
# --- 強制の向き ---------------------------------------------------------------
#   非ゼロ終了が block である。Claude Code / シェル wrapper から呼ばれるので、
#   Codex hook のような fail-open 規約（常に exit 0）は適用しない。
#   LANE_BASEPOINT_ENFORCE=0 で警告のみへ降格できるが、降格したこと自体を
#   防御台帳へ記帳するので「黙って外す」ことはできない。
#
# --- 廃止条件 -----------------------------------------------------------------
#   block の誤検知率（基点が古いと判定されたが実際には重複が起きなかった）が
#   四半期 50% を超えたら behind 閾値を緩める。発火ゼロ 90 日で降格候補。
set -uo pipefail

_LEDGER_LIB=""
for _cand in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hooks/lib/aidd-ledger.sh" \
  "$HOME/.claude/hooks/lib/aidd-ledger.sh"
do
  [ -f "$_cand" ] && _LEDGER_LIB="$_cand" && break
done
# shellcheck source=/dev/null
[ -n "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# 何 commit 遅れたら止めるか。0 = 1 commit でも遅れていれば止める。
BEHIND_LIMIT="${LANE_BEHIND_LIMIT:-0}"

ledger() {
  # ledger <event> <rule> <detail> <subject-json>
  declare -F aidd_ledger_append_record >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" "$3" "$4" <<'PY' | while IFS= read -r row; do
import json, sys
event, rule, detail, subject = sys.argv[1:5]
try:
    subj = json.loads(subject)
except ValueError:
    subj = {"raw": subject}
print(json.dumps({"component": "H11", "event": event, "rule": rule,
                  "detail": detail, "subject": subj},
                 ensure_ascii=False, separators=(",", ":")))
PY
    aidd_ledger_append_record "$row" "${LANE_LEDGER_SOURCE:-claude-code}" >/dev/null 2>&1 || true
  done
}

die() { printf '::error::%s\n' "$*" >&2; }
note() { printf '[lane-basepoint] %s\n' "$*" >&2; }

# resolve_base <worktree> — base ブランチ名を決める。
# 明示 > origin/HEAD > develop > main。推測した場合はその旨を出す。
resolve_base() {
  local wt="$1" ref
  if [ -n "${LANE_BASE:-}" ]; then
    printf '%s' "${LANE_BASE#origin/}"
    return 0
  fi
  ref="$(git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    printf '%s' "${ref##*/}"
    return 0
  fi
  for cand in develop main master; do
    if git -C "$wt" rev-parse --verify --quiet "origin/$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# check_basepoint_ref <repo> <commit-ish> <base>
#
# 発射*前*の判定。`git worktree add` の瞬間には worktree ディレクトリがまだ
# 存在しないので、check_basepoint（既存 worktree の HEAD を見る）は使えない。
# 代わりに「これから checkout される起点」が base より遅れていないかを見る。
#
# commit-ish は既存ブランチ名でも start-point でもよい。解決できない場合は
# **通す**。存在しないブランチを作る形（`-b new <path>` で start 省略）では
# git 自身が HEAD を起点にするが、その HEAD がどれかを hook 側で確実に決める
# 手段がなく、誤って止めると新規レーンが一切作れなくなるためである。
check_basepoint_ref() {
  local repo="$1" ref="$2" base="$3" behind start
  git -C "$repo" fetch origin "$base" --quiet 2>/dev/null || \
    note "fetch origin $base に失敗（オフライン？）。ローカルの origin/$base で判定する"
  if ! git -C "$repo" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
    note "origin/$base が解決できない: 基点判定を省略する"
    return 0
  fi
  start="$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)"
  if [ -z "$start" ]; then
    note "起点 '$ref' を解決できない: 基点判定を省略する（新規ブランチの可能性）"
    return 0
  fi
  behind="$(git -C "$repo" rev-list --count "$start..origin/$base" 2>/dev/null || echo 0)"
  local subject
  subject="$(printf '{"repo":"%s","start_ref":"%s","start":"%s","base":"origin/%s","behind":%s,"limit":%s}' \
    "$repo" "$ref" "$start" "$base" "$behind" "$BEHIND_LIMIT")"

  # 比較の向きを check_basepoint と textually 変えてある。同じ字面にすると
  # tests/test-lane-basepoint.sh の変異体が「最初の一致」でこちらを掴み、
  # 意図した check_basepoint ではなく本関数を変異させてしまう（実測で踏んだ）。
  if [ "$BEHIND_LIMIT" -ge "$behind" ]; then
    note "起点 OK: '$ref' は origin/$base より $behind commit 遅れ"
    ledger pass stale-basepoint "behind=$behind (pre-launch)" "$subject"
    return 0
  fi

  die "発射しようとしている起点が origin/${base} より ${behind} commit 古い: ${ref}"
  die "  その間に他レーンの成果が ${base} へ入っている。同じ領域を独立に再実装すると"
  die "  add/add 競合になり、成熟度の低い側が破棄される（Grift feat/l-s6-api: 650 行 vs 290 行）。"
  die "  起点を取り直す:  git -C ${repo} fetch origin ${base} && <worktree add を origin/${base} 起点で再実行>"
  ledger block stale-basepoint "start ref '$ref' is $behind commits behind origin/$base (pre-launch)" "$subject"
  return 1
}

check_basepoint() {
  local wt="$1" base="$2" behind ahead
  git -C "$wt" fetch origin "$base" --quiet 2>/dev/null || \
    note "fetch origin $base に失敗（オフライン？）。ローカルの origin/$base で判定する"
  if ! git -C "$wt" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
    die "origin/$base が解決できない。LANE_BASE で base を明示すること。"
    ledger error stale-basepoint "origin/$base 未解決" \
      "$(printf '{"worktree":"%s","base":"%s"}' "$wt" "$base")"
    return 2
  fi
  behind="$(git -C "$wt" rev-list --count "HEAD..origin/$base" 2>/dev/null || echo 0)"
  ahead="$(git -C "$wt" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 0)"
  local subject
  subject="$(printf '{"worktree":"%s","base":"origin/%s","behind":%s,"ahead":%s,"limit":%s}' \
    "$wt" "$base" "$behind" "$ahead" "$BEHIND_LIMIT")"

  if [ "$behind" -le "$BEHIND_LIMIT" ]; then
    note "基点 OK: origin/$base より $behind commit 遅れ (ahead $ahead)"
    ledger pass stale-basepoint "behind=$behind" "$subject"
    return 0
  fi

  die "worktree の基点が origin/${base} より ${behind} commit 古い: ${wt}"
  die "  その間に他レーンの成果が ${base} へ入っている可能性がある。"
  die "  同一ファイルを独立に再実装すると add/add 競合になり、成熟度の低い側が破棄される。"
  die "  切り直す:  git -C ${wt} fetch origin ${base} && git -C ${wt} rebase origin/${base}"
  ledger block stale-basepoint "worktree is $behind commits behind origin/$base" "$subject"
  return 1
}

check_duplicates() {
  local wt="$1" base="$2" dupes=0 added path list
  if ! git -C "$wt" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
    return 0
  fi
  # このブランチが新規作成したファイル。merge-base 起点 (三点) で見るので、
  # base 側の後続コミットが足したファイルは "このブランチの新規" に入らない。
  added="$(git -C "$wt" diff --diff-filter=A --name-only "origin/$base...HEAD" 2>/dev/null || true)"
  [ -z "$added" ] && { note "新規作成ファイルなし: 重複判定の対象が無い"; return 0; }
  list=""
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    # base 側に同名が既に存在する = 両側が独立に同じファイルを新規作成した。
    if git -C "$wt" cat-file -e "origin/$base:$path" 2>/dev/null; then
      dupes=$((dupes + 1))
      list="${list}${list:+,}$path"
      die "重複実装: このブランチが新規作成した ${path} は origin/${base} に既に存在する"
    fi
  done <<<"$added"

  local subject
  subject="$(python3 -c '
import json, sys
print(json.dumps({"worktree": sys.argv[1], "base": "origin/" + sys.argv[2],
                  "duplicate_files": [p for p in sys.argv[3].split(",") if p],
                  "duplicates": int(sys.argv[4])}, ensure_ascii=False))' \
    "$wt" "$base" "$list" "$dupes")"

  if [ "$dupes" -eq 0 ]; then
    note "重複なし: 新規作成ファイルはいずれも origin/$base に存在しない"
    ledger pass duplicate-implementation "duplicates=0" "$subject"
    return 0
  fi
  die "add/add 競合が ${dupes} 件見込まれる。マージ前に、真に新規な部分だけを"
  die "  新規ファイルへ分離すること（既存ファイルへの追加は interface 宣言に留める）。"
  ledger block duplicate-implementation "$dupes duplicate file(s) vs origin/$base" "$subject"
  return 1
}

# --- 共有チェックアウト (#91 項目 2) -----------------------------------------
#
# 2026-09-03 の事故 2 件は、いずれも「1 チェックアウトを複数レーンが共有した」
# ことが原因である。issue #91 項目 2 の原文（Grift の add/add = 別ブランチが
# 同じファイルを独立実装）とは**別種**なので、両方を分けて扱う。
#
#   事故 1: 監督が共有チェックアウトで `git checkout -b <新>` を実行 →
#           別レーンが同じツリーを使っていたため失敗 → `2>/dev/null || <fallback>`
#           で失敗を握り潰した → 続く `git add` + `git commit` が
#           **他レーンのブランチに載った**。
#             dfe65f1 test(matrix): …    ← 他レーン
#             c65dadb test: シェル変数の… ← 監督の commit が潜り込んだ
#   事故 2: 逆方向。監督が共有チェックアウトのブランチを切り替えたところ、
#           その時点で別レーンが同じツリーで作業中だった。
#
# 「共有」の定義は実測で決めた。main worktree か linked worktree かは
# `<absolute-git-dir>/gitdir` の有無で決まる（linked にだけ存在する）。実測:
#   MAIN    n=55  /Users/…/claude-code-skills/.git
#   LINKED  n=15  /Users/…/aidd-governance/.git/worktrees/convergence
#   MAIN    n=1   （worktree を 1 本も持たない素のリポジトリ）
# **レーン自身の worktree は LINKED なので、この判定はレーンを巻き込まない。**
# 巻き込むのは「linked worktree を 1 本以上抱えた main チェックアウト」だけ、
# つまりレーンが共有している当のツリーである。
is_shared_checkout() {
  local repo="$1" agd n
  agd="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$agd" ] || return 1
  # linked worktree は 1 レーンの専有物。切り替えても他レーンに当たらない。
  [ -f "$agd/gitdir" ] && return 1
  n="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
  [ "${n:-0}" -ge 2 ]
}

# check_shared_checkout <repo> <operation> [detail]
#
# 強制の向き: 共有チェックアウトでの**ブランチ変更と無差別ステージング**を止め、
# worktree へ誘導する。`git commit` そのものは止めない — 15 worktree を抱えた
# 監督用チェックアウトで commit を全面禁止すると、文書作業が一切できなくなる。
# 事故 1 で commit が誤爆したのは commit が悪いからではなく、**その前の
# branch 変更の失敗を握り潰した**からである。そこを止めれば commit は誤爆しない。
check_shared_checkout() {
  local repo="$1" op="$2" detail="${3:-}" n linked branch subject
  is_shared_checkout "$repo" || return 0
  n="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
  linked=$(( ${n:-1} - 1 ))
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  subject="$(printf '{"repo":"%s","operation":"%s","current_branch":"%s","linked_worktrees":%s}' \
    "$repo" "$op" "$branch" "$linked")"

  die "共有チェックアウトで ${op} を実行しようとしている: ${repo}"
  die "  このチェックアウトには linked worktree が ${linked} 本ぶら下がっており、"
  die "  現在 ${branch} を指している。他レーンが同じツリーを使っている可能性がある。"
  die "  2026-09-03 に実際に起きたこと: ブランチ生成の失敗を握り潰し、続く commit が"
  die "  他レーンのブランチに載った（c65dadb が dfe65f1 の上に潜り込んだ）。"
  die "  worktree を切って作業すること:"
  die "    git -C ${repo} worktree add ${repo}/.worktrees/<agent>/<slug> -b <branch> origin/<base>"
  [ -n "$detail" ] && die "  検出した入力: ${detail}"
  ledger block shared-checkout "$op in shared checkout ($linked linked worktrees)" "$subject"
  return 1
}

# --- 稼働中レーンとの担当領域の重複 (#91 項目 2 原文) --------------------------
#
# duplicates モードは「base に既に在るファイル」しか見ない = **着地済みの成果**
# しか見えない。並列レーンの本当の衝突相手は、まだ着地していない別 worktree
# である。ここはその差を埋める。
#
# レジストリは作らない。稼働中 worktree の diff から導出する。宣言と実体を
# 二重に持つと片方だけ古くなって嘘をつく（本リポジトリが繰り返し踏んだ形）。
# 判定材料は LANE_PATHS（改行区切り、#88 と同じ宣言欄を使い回す）。
#
# 警告であって block ではない。他レーンが触ったファイルへ正当に追記する場合が
# あり、54 worktree 規模では prefix 一致が常時発火する。**block の値打ちが
# 誤検知で溶ける**ので、記帳して見えるようにするところまでに留める。
check_overlap() {
  local repo="$1" wt self_wt hits=0 report="" changed base overlap subject
  [ -n "${LANE_PATHS:-}" ] || { note "LANE_PATHS 未宣言: 担当領域の重複判定を省略する"; return 0; }
  base="$(resolve_base "$repo" 2>/dev/null || true)"
  [ -n "$base" ] || { note "base を決められない: 担当領域の重複判定を省略する"; return 0; }
  base="${base#origin/}"
  self_wt="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"

  while IFS= read -r wt; do
    wt="${wt#worktree }"
    [ -n "$wt" ] || continue
    [ "$wt" = "$self_wt" ] && continue
    [ -d "$wt" ] || continue
    # そのレーンが fork 点以降に触ったファイル（= まだ着地していない作業）。
    # commit 済みだけでは足りない。実測 (2026-09-03, aidd-governance):
    #   cluster-a/convergence  ahead=0 だが未コミット 16 ファイル
    #   （.github/workflows/homonym-guard-ci.yml を含む）
    # レーンは長時間コミットせずに作業する。commit 済みしか見ないと、
    # **まさに衝突が起きている最中のレーンが見えない**。作業ツリーも足す。
    changed="$( { git -C "$wt" diff --name-only "origin/$base...HEAD" 2>/dev/null || true
                  git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null \
                    | sed -e 's/^...//' -e 's/.* -> //' || true
                } | sort -u )"
    [ -n "$changed" ] || continue
    # 宣言と変更一覧は argv で渡す。heredoc とパイプは併用できない（SC2259）。
    overlap="$(python3 - "${LANE_PATHS:-}" "$changed" <<'PY' || true
import sys
declared = [p.strip() for p in sys.argv[1].splitlines() if p.strip()]
changed = [c.strip() for c in sys.argv[2].splitlines() if c.strip()]
print("\n".join(sorted({c for c in changed for d in declared
                        if c == d or c.startswith(d.rstrip("/") + "/")})))
PY
)"
    [ -n "$overlap" ] || continue
    hits=$((hits + 1))
    report="${report}${report:+$'\n'}  ${wt}: $(printf '%s' "$overlap" | tr '\n' ' ')"
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^worktree ')

  subject="$(python3 -c '
import json, sys
print(json.dumps({"repo": sys.argv[1],
                  "declared": [p for p in sys.argv[2].splitlines() if p.strip()],
                  "overlapping_worktrees": int(sys.argv[3])}, ensure_ascii=False))' \
    "$repo" "${LANE_PATHS:-}" "$hits")"

  if [ "$hits" -eq 0 ]; then
    note "担当領域の重複なし: 宣言したパスを触っている稼働中 worktree は無い"
    ledger pass lane-area-overlap "overlap=0" "$subject"
    return 0
  fi
  note "担当領域が稼働中の ${hits} レーンと重複している（着地前なので base には現れない）:"
  printf '%s\n' "$report" >&2
  note "  同じファイルを独立に実装すると add/add になる。分担を確認すること。"
  ledger warn lane-area-overlap "overlap with $hits live worktree(s)" "$subject"
  return 0
}

usage() {
  cat >&2 <<'EOF'
usage: lane-basepoint-check.sh <basepoint|duplicates|check> <worktree-path> [base-branch]
       lane-basepoint-check.sh basepoint-ref <repo-path> <commit-ish> [base-branch]
       lane-basepoint-check.sh shared-checkout <repo-path> <operation> [detail]
       lane-basepoint-check.sh overlap <repo-path>

  basepoint       worktree が base より遅れていないか（既存 worktree 向け）
  basepoint-ref   これから checkout する起点が base より遅れていないか
                  （worktree 作成 *前* の判定。ディレクトリはまだ存在しない）
  duplicates      このブランチが新規作成したファイルが base に既に在るか（add/add 先回り）
  check           basepoint + duplicates
  shared-checkout linked worktree を抱えた main チェックアウトでの破壊的操作か
                  （非ゼロ = block。2026-09-03 の事故 2 件）
  overlap         LANE_PATHS 宣言が稼働中の他 worktree と重なるか（警告のみ、常に 0）

env:
  LANE_BASE                 base ブランチ名を明示（既定: origin/HEAD -> develop -> main）
  LANE_BEHIND_LIMIT         許容する behind commit 数（既定 0）
  LANE_BASEPOINT_ENFORCE    0 で警告のみへ降格（降格したことを台帳へ記帳する）
  LANE_PATHS                触る予定のパス（改行区切り）。overlap の判定材料
  LANE_SHARED_ENFORCE       0 で shared-checkout の block を warn へ降格（記帳する）
EOF
}

main() {
  local mode="${1:-}" wt="${2:-}" base="${3:-}"
  case "$mode" in
    basepoint | duplicates | check) ;;
    shared-checkout)
      # 引数の意味が違う: <repo> <operation> [detail]
      local srepo="${2:-}" sop="${3:-}" sdetail="${4:-}"
      [ -n "$srepo" ] && [ -n "$sop" ] || { usage; return 2; }
      git -C "$srepo" rev-parse --git-dir >/dev/null 2>&1 || {
        die "git リポジトリではない: $srepo"; return 2; }
      check_shared_checkout "$srepo" "$sop" "$sdetail"
      local src=$?
      if [ "$src" -eq 1 ] && [ "${LANE_SHARED_ENFORCE:-1}" = "0" ]; then
        note "LANE_SHARED_ENFORCE=0 のため block を warn へ降格した"
        ledger warn shared-checkout-bypassed "block downgraded by LANE_SHARED_ENFORCE=0" \
          "$(printf '{"repo":"%s","operation":"%s"}' "$srepo" "$sop")"
        return 0
      fi
      return "$src"
      ;;
    overlap)
      local orepo="${2:-}"
      [ -n "$orepo" ] || { usage; return 2; }
      git -C "$orepo" rev-parse --git-dir >/dev/null 2>&1 || {
        die "git リポジトリではない: $orepo"; return 2; }
      check_overlap "$orepo"
      return 0
      ;;
    basepoint-ref)
      # 引数の意味が違う: <repo> <commit-ish> [base]
      local repo="${2:-}" ref="${3:-}" rbase="${4:-}"
      [ -n "$repo" ] && [ -n "$ref" ] || { usage; return 2; }
      git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        die "git リポジトリではない: $repo"; return 2; }
      if [ -z "$rbase" ]; then
        rbase="$(resolve_base "$repo")" || { note "base を決められない: 判定を省略"; return 0; }
      fi
      rbase="${rbase#origin/}"
      check_basepoint_ref "$repo" "$ref" "$rbase"
      local rrc=$?
      if [ "$rrc" -eq 1 ] && [ "${LANE_BASEPOINT_ENFORCE:-1}" = "0" ]; then
        note "LANE_BASEPOINT_ENFORCE=0 のため block を warn へ降格した"
        ledger warn basepoint-bypassed "block downgraded by LANE_BASEPOINT_ENFORCE=0" \
          "$(printf '{"repo":"%s","ref":"%s","base":"origin/%s","mode":"basepoint-ref"}' "$repo" "$ref" "$rbase")"
        return 0
      fi
      return "$rrc"
      ;;
    *) usage; return 2 ;;
  esac
  [ -n "$wt" ] || { usage; return 2; }
  if [ ! -d "$wt" ]; then
    die "worktree が存在しない: $wt"
    return 2
  fi
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    die "git 作業ツリーではない: $wt"
    return 2
  fi
  if [ -z "$base" ]; then
    base="$(resolve_base "$wt")" || {
      die "base ブランチを決められない。LANE_BASE で明示すること。"
      return 2
    }
  fi
  base="${base#origin/}"

  local rc=0 sub=0
  if [ "$mode" = basepoint ] || [ "$mode" = check ]; then
    check_basepoint "$wt" "$base"; sub=$?
    [ "$sub" -gt "$rc" ] && rc=$sub
  fi
  if [ "$mode" = duplicates ] || [ "$mode" = check ]; then
    check_duplicates "$wt" "$base"; sub=$?
    [ "$sub" -gt "$rc" ] && rc=$sub
  fi

  # 降格は「黙って外す」ことができないよう、降格の事実を記帳してから返す。
  if [ "$rc" -eq 1 ] && [ "${LANE_BASEPOINT_ENFORCE:-1}" = "0" ]; then
    note "LANE_BASEPOINT_ENFORCE=0 のため block を warn へ降格した"
    ledger warn basepoint-bypassed "block downgraded by LANE_BASEPOINT_ENFORCE=0" \
      "$(printf '{"worktree":"%s","base":"origin/%s","mode":"%s"}' "$wt" "$base" "$mode")"
    return 0
  fi
  return "$rc"
}

main "$@"
