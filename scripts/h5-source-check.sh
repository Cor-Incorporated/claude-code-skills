#!/usr/bin/env bash
# h5-source-check.sh — vendor した h5-admission-check.sh の同一性検査 (aidd-governance#137)
#
# 単一正本 + vendoring の強制点。**2 つのモードに分けてあるのが本体である。**
#
#   offline : 本体の sha256 を再計算し、スタンプの値と照合する。network 不要。
#             毎 PR で必ず走る。**正本側でも消費側でも意味を持つ**:
#               role=source → 公開している sha と本体がずれていないか
#                             （本体を直してスタンプを直し忘れた、を捕まえる）
#               role=vendor → vendor したコピーが改変されていないか
#   online  : 正本を fetch してスタンプと比較する。drift を検出する。
#             **role=vendor のリポジトリでのみ意味を持つ。**
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
# 正本の向き (aidd-governance#137): **claude-code-skills が正本、public** である。
# gov を正本にすると、public 側の CI トークンは private な gov を読めず online 検査が
# 恒久的に UNVERIFIED になる（実測 2026-09-03, ccs#368）。向きを逆にすると
# private → public は常に読めるので **secret が 1 本も要らない**。
# 加えて ccs は main/develop とも required_status_checks に h5-admission を持つ。
# 強制が最も強い側に正本を置く。
#
# exit 0 = 一致 / 1 = 不一致 (drift or 改変 or 誤用) / 2 = 検査できなかった (online のみ)
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

# 追加被覆 (aidd-governance#144): `sha256:<repo相対パス>=<hash>` 行を列挙する。
# `sha256=` は本体 (h5-admission-check.sh) 専用のまま残す。**加算的な拡張**で、
# 旧い検査器はこの行を読まない（awk -F= の $1 が `sha256:<path>` になり
# `sha256` と一致しないため。実測 2026-09-03、行順にも依存しない）。
# したがって「片方が新書式・片方が旧書式」の移行期でも既存照合は壊れない。
stamp_extra_paths() { # -> "<path>\t<sha>" を 1 行ずつ
  [[ -f "$STAMP" ]] || return 0
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*sha256:/ {
      line = $0
      sub(/^[[:space:]]*sha256:/, "", line)
      idx = index(line, "=")
      if (idx < 2) next
      p = substr(line, 1, idx - 1)
      h = substr(line, idx + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
      if (p != "" && h != "") printf "%s\t%s\n", p, h
    }
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
role="$(stamp_get role || true)"
for k in sha256:want_sha source:src_repo ref:src_ref role:role; do
  key="${k%%:*}"; var="${k##*:}"
  if [[ -z "${!var}" ]]; then fail "スタンプに $key= がない: $STAMP"; exit 1; fi
done
# role は閉語彙。未知の値を「たぶん vendor だろう」と読まない。
case "$role" in
  source|vendor) ;;
  *) fail "role の値が不正: '$role'（source | vendor のみ）"; exit 1 ;;
esac
if [[ ! "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
  # バリデーションから失敗モードを逆算 (runbook.md): バッククォート・大文字・改行混入
  fail "sha256 の書式が不正: '$want_sha'（^[0-9a-f]{64}$ に一致しない）"
  exit 1
fi

case "$MODE" in
offline)
  offline_bad=0
  got_sha="$(sha256_of "$BODY")" || { fail "sha256 を計算できない（sha256sum も shasum も無い）"; exit 1; }
  if [[ "$got_sha" != "$want_sha" ]]; then
    # runbook.md rule C: 期待値だけでなく観測値も出す。片方だけでは直せない。
    fail "スタンプと一致しない: scripts/h5-admission-check.sh"
    fail "  stamp  sha256 = $want_sha"
    fail "  actual sha256 = $got_sha"
    fail "  file          = $BODY"
    offline_bad=$((offline_bad + 1))
  fi
  # 追加被覆分 (#144)。1 件ずつ「どのファイルが / 期待 / 実測」を出す。
  covered=1
  while IFS="$(printf '\t')" read -r p want; do
    [[ -z "$p" ]] && continue
    covered=$((covered + 1))
    if [[ ! -f "$ROOT/$p" ]]; then
      fail "スタンプが覆うファイルが存在しない: $p"
      fail "  stamp sha256 = $want"
      offline_bad=$((offline_bad + 1))
      continue
    fi
    got="$(sha256_of "$ROOT/$p")" || { fail "sha256 を計算できない: $p"; offline_bad=$((offline_bad + 1)); continue; }
    if [[ "$got" != "$want" ]]; then
      fail "スタンプと一致しない: $p"
      fail "  stamp  sha256 = $want"
      fail "  actual sha256 = $got"
      fail "  file          = $ROOT/$p"
      offline_bad=$((offline_bad + 1))
    fi
  done <<<"$(stamp_extra_paths)"

  if [[ "$offline_bad" -eq 0 ]]; then
    log "H5-SOURCE-OK (offline): 被覆 $covered ファイルがすべてスタンプと一致する"
    log "  source=$src_repo ref=$src_ref commit=${src_commit:-<none>}"
    log "  sha256=$got_sha (scripts/h5-admission-check.sh)"
    stamp_extra_paths | while IFS="$(printf '\t')" read -r p _; do [[ -n "$p" ]] && log "  covered: $p"; done
    exit 0
  fi
  fail "$offline_bad 件がスタンプと一致しない（ローカル改変の疑い / 被覆 $covered ファイル）"
  fail "対処: 正本 $src_repo@$src_ref から vendor し直し、スタンプも更新する"
  fail "これらのファイルをこのリポジトリで直接編集してはならない (aidd-governance#137 / #144)"
  exit 1
  ;;
online)
  # 正本リポジトリには照合すべき上流が無い。ここで exit 0 を返すと
  # 「上流を見ていないのに緑」になるので、明示的に誤用として落とす。
  if [[ "$role" == "source" ]]; then
    fail "このリポジトリは正本 (role=source) であり、照合する上流が無い"
    fail "online 検査を配線してよいのは role=vendor のリポジトリだけである"
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    unver "gh が無いため正本を取得できなかった — **緑にしない**"
    exit 2
  fi
  src_owner="${src_repo%%/*}"; src_name="${src_repo##*/}"

  # 正本から 1 ファイル取って sha256 を返す。取得できなければ 2 を返す。
  # owner と repo を別セグメントで書く。1 変数へ "owner/repo" を入れると
  # claude-code-skills の workflow-permission-scan.py が `repos/{}/contents/...`
  # と読み、宣言済みの `repos/{owner}/{repo}/contents/{path}` に当たらず
  # UNDECIDABLE-API になる（実測 2026-09-03, ccs#368 の CI）。
  fetch_upstream_sha() { # <repo相対パス> -> stdout に sha / rc 2 で取得失敗
    local rp="$1" tmp err rc
    tmp="$(mktemp)"; err="$(mktemp)"
    if ! gh api "repos/${src_owner}/${src_name}/contents/${rp}?ref=${src_ref}" \
          --jq '.content' 2>"$err" | base64 -d > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
      # #349 の原則: 相手側が見えないとき PASS にしない。SKIP でもなく UNVERIFIED。
      # ただし「なぜ見えないか」を分けて出す。恒久的に見えない（権限）と
      # 一時的に見えない（network）は対処がまったく違うのに、同じ赤だと
      # 「いつもの赤」として無視される。
      if grep -qiE 'Not Found|HTTP 404|Resource not accessible|HTTP 403' "$err" 2>/dev/null; then
        unver "正本 $src_repo@$src_ref の $rp を **読む権限が無い、または存在しない**（404/403）"
        unver "正本が private で実行中のトークンが読めない場合、またはパスが正本に無い場合これになる。"
        unver "**この状態は恒久的である。** 再実行しても直らない。"
      else
        unver "正本 $src_repo@$src_ref の $rp を取得できなかった（network）"
      fi
      [[ -s "$err" ]] && sed -e 's/^/  gh: /' "$err" >&2
      rm -f "$tmp" "$err"
      return 2
    fi
    rm -f "$err"
    sha256_of "$tmp" || { rm -f "$tmp"; return 2; }
    rm -f "$tmp"
    return 0
  }

  online_bad=0
  covered=1
  # 本体。1 件でも取得できなければ「照合していない」ので exit 2 で抜ける。
  if ! up_sha="$(fetch_upstream_sha "scripts/h5-admission-check.sh")"; then
    unver "照合していないので緑にしない。exit 2 = 検査できなかった"
    exit 2
  fi
  if [[ "$up_sha" != "$want_sha" ]]; then
    fail "正本が先へ進んでいる: scripts/h5-admission-check.sh"
    fail "  stamp    sha256 = $want_sha"
    fail "  upstream sha256 = $up_sha"
    online_bad=$((online_bad + 1))
  fi
  # 追加被覆分 (#144)
  while IFS="$(printf '\t')" read -r p want; do
    [[ -z "$p" ]] && continue
    covered=$((covered + 1))
    if ! up="$(fetch_upstream_sha "$p")"; then
      unver "照合していないので緑にしない。exit 2 = 検査できなかった（${p}）"
      exit 2
    fi
    if [[ "$up" != "$want" ]]; then
      fail "正本が先へ進んでいる: $p"
      fail "  stamp    sha256 = $want"
      fail "  upstream sha256 = $up"
      online_bad=$((online_bad + 1))
    fi
  done <<<"$(stamp_extra_paths)"

  if [[ "$online_bad" -eq 0 ]]; then
    log "H5-SOURCE-OK (online): 被覆 $covered ファイルが正本 $src_repo@$src_ref と一致する"
    log "  sha256=$up_sha (scripts/h5-admission-check.sh)"
    stamp_extra_paths | while IFS="$(printf '\t')" read -r p _; do [[ -n "$p" ]] && log "  covered: $p"; done
    exit 0
  fi
  fail "$online_bad 件が正本から遅れている（被覆 $covered ファイル / upstream=${src_repo}@${src_ref}）"
  fail "対処: 正本から vendor し直す PR を出す"
  exit 1
  ;;
*)
  fail "unknown mode: ${MODE}（offline | online）"; exit 1 ;;
esac
