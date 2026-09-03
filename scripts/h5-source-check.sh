#!/usr/bin/env bash
# h5-source-check.sh — vendor した h5-admission-check.sh の同一性検査 (aidd-governance#137)
#
# 単一正本 + vendoring の強制点。**2 つのモードに分けてあるのが本体である。**
#
#   offline : vendor 済み本体の sha256 を再計算し、スタンプの値と照合する。
#             network 不要。毎 PR で必ず走る。ローカル改変を検出する。
#   online  : 正本を fetch し、スタンプの sha256 と比較する。drift を検出する。
#
# **なぜ 1 本にしないか。**
# claude-code-skills#349「pair テストが skip を PASS に計上し、CI の "15 passed" が
# 実際には 5 件しか照合していない」で、**相手側が見えない pair は PASS ではなく
# SKIP** という原則が確立している (tests/test-pairs-link.sh の skip())。
# online 検査は upstream の fetch に失敗しうる。1 本にすると、network 障害が
# 「照合していないのに緑」を作る。したがって:
#
#   - offline は network に依存しない不変条件として毎 PR で走る
#   - online は fetch 失敗を **exit 2 (UNVERIFIED)** として扱い、**緑にしない**
#     SKIP でもない。「検査できなかった」ことが exit code で観測できる形にする
#
# exit 0 = 一致 / 1 = 不一致 (drift or 改変) / 2 = 検査できなかった (online のみ)
set -uo pipefail

ROOT="${H5_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BODY="${H5_SOURCE_BODY:-$ROOT/scripts/h5-admission-check.sh}"
STAMP="${H5_SOURCE_STAMP:-$ROOT/scripts/h5-admission-check.source}"
MODE="${1:-offline}"

log() { printf '%s\n' "$*"; }
fail() { printf 'H5-SOURCE-FAIL: %s\n' "$*" >&2; }
unver() { printf 'H5-SOURCE-UNVERIFIED: %s\n' "$*" >&2; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

stamp_get() { # <key>
  [[ -f "$STAMP" ]] || return 1
  awk -F= -v k="$1" '
    /^[[:space:]]*(#|$)/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == k) { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit } }
  ' "$STAMP"
}

# --- 前提の存在確認。無いことを黙って通さない ---
if [[ ! -f "$BODY" ]]; then
  fail "本体が無い: $BODY"; exit 1
fi
if [[ ! -f "$STAMP" ]]; then
  fail "スタンプが無い: $STAMP"
  fail "vendor したリポジトリは scripts/h5-admission-check.source を持たねばならない"
  exit 1
fi

want_sha="$(stamp_get sha256 || true)"
src_repo="$(stamp_get source || true)"
src_ref="$(stamp_get ref || true)"
src_commit="$(stamp_get commit || true)"
for k in sha256:want_sha source:src_repo ref:src_ref; do
  key="${k%%:*}"; var="${k##*:}"
  if [[ -z "${!var}" ]]; then fail "スタンプに $key= がない: $STAMP"; exit 1; fi
done
if [[ ! "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
  # バリデーションから失敗モードを逆算 (runbook.md): バッククォート・大文字・改行混入
  fail "sha256 の書式が不正: '$want_sha'（^[0-9a-f]{64}$ に一致しない）"
  exit 1
fi

case "$MODE" in
offline)
  got_sha="$(sha256_of "$BODY")" || { fail "sha256 を計算できない（sha256sum も shasum も無い）"; exit 1; }
  if [[ "$got_sha" == "$want_sha" ]]; then
    log "H5-SOURCE-OK (offline): $BODY は スタンプと一致する"
    log "  source=$src_repo ref=$src_ref commit=${src_commit:-<none>}"
    log "  sha256=$got_sha"
    exit 0
  fi
  # runbook.md rule C: 期待値だけでなく観測値も出す。片方だけでは直せない。
  fail "vendor 済み本体がスタンプと一致しない（ローカル改変の疑い）"
  fail "  stamp  sha256 = $want_sha"
  fail "  actual sha256 = $got_sha"
  fail "  body          = $BODY"
  fail "対処: 正本 $src_repo@$src_ref から vendor し直し、スタンプも更新する"
  fail "本体をこのリポジトリで直接編集してはならない (aidd-governance#137)"
  exit 1
  ;;
online)
  if ! command -v gh >/dev/null 2>&1; then
    unver "gh が無いため正本を取得できなかった — **緑にしない**"
    exit 2
  fi
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  # owner と repo を別セグメントで書く。1 変数へ "owner/repo" を入れると
  # claude-code-skills の workflow-permission-scan.py が
  # `repos/{}/contents/...` と読み、宣言済みの `repos/{owner}/{repo}/contents/{path}`
  # に当たらず UNDECIDABLE-API になる（実測 2026-09-03, ccs#368 の CI）。
  # 宣言を増やすのではなく呼び出し側を正す。
  src_owner="${src_repo%%/*}"; src_name="${src_repo##*/}"
  body_path="scripts/h5-admission-check.sh"
  err="$(mktemp)"
  if ! gh api "repos/${src_owner}/${src_name}/contents/${body_path}?ref=${src_ref}" \
        --jq '.content' 2>"$err" | base64 -d > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    # #349 の原則: 相手側が見えないとき PASS にしない。SKIP でもなく UNVERIFIED。
    # ただし「なぜ見えないか」を分けて出す。恒久的に見えない（権限）と
    # 一時的に見えない（network）は対処がまったく違うのに、同じ赤だと
    # 「いつもの赤」として無視される。
    if grep -qiE 'Not Found|HTTP 404|Resource not accessible|HTTP 403' "$err" 2>/dev/null; then
      unver "正本 $src_repo@$src_ref を **読む権限が無い**（404/403）"
      unver "正本が private で、実行中のトークンが当該リポジトリを読めない場合これになる。"
      unver "対処は 2 つ: (1) cross-repo read が可能な token を secret で渡す"
      unver "          (2) 正本を、消費側から読めるリポジトリへ置く"
      unver "**この状態は恒久的である。** 再実行しても直らない。"
    else
      unver "正本 $src_repo@$src_ref を取得できなかった（network / ref 不在）"
    fi
    [[ -s "$err" ]] && sed -e 's/^/  gh: /' "$err" >&2
    unver "照合していないので緑にしない。exit 2 = 検査できなかった"
    rm -f "$err"
    exit 2
  fi
  rm -f "$err"
  up_sha="$(sha256_of "$tmp")" || { unver "sha256 を計算できない"; exit 2; }
  if [[ "$up_sha" == "$want_sha" ]]; then
    log "H5-SOURCE-OK (online): スタンプは正本 $src_repo@$src_ref と一致する"
    log "  sha256=$up_sha"
    exit 0
  fi
  fail "正本が先へ進んでいる（vendor が古い）"
  fail "  stamp    sha256 = $want_sha"
  fail "  upstream sha256 = $up_sha"
  fail "  upstream        = $src_repo@$src_ref"
  fail "対処: 正本から vendor し直す PR を出す"
  exit 1
  ;;
*)
  fail "unknown mode: ${MODE}（offline | online）"; exit 1 ;;
esac
