#!/usr/bin/env bash
# scripts/h5-source-check.sh の反証テスト (aidd-governance#137)。
#
# 押さえる命題:
#   (a) vendor 済み本体を 1 バイト書き換えると offline 検査が red
#   (b) 正本を fetch できないとき online 検査が **緑にならない**（exit 2 = UNVERIFIED）
#   (F3) スタンプの sha256 を 1 文字変えると offline 検査が red
#
# (b) が本テストの中心である。claude-code-skills#349 で確立した
# 「相手側が見えない pair は PASS ではなく SKIP」の原則を、ここでは
# 「PASS でも SKIP でもなく UNVERIFIED (exit 2)」として実装している。
# **exit 0 を返したらテストが落ちる。** network 障害で緑になる形を作らないため。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/scripts/h5-source-check.sh"
BODY_SRC="$ROOT/scripts/h5-admission-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "  $2"; fail=$((fail + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# vendor 済みリポジトリの fixture を作る。
mkvendor() { # <name> [sha-override] [role] -> fixture root
  local name="$1" override="${2:-}" d s
  d="$WORK/$name"
  mkdir -p "$d/scripts"
  cp "$BODY_SRC" "$d/scripts/h5-admission-check.sh"
  s="$(sha256_of "$d/scripts/h5-admission-check.sh")"
  [[ -n "$override" ]] && s="$override"
  cp "$ROOT/scripts/h5-source-check.sh" "$d/scripts/h5-source-check.sh"
  local cs
  cs="$(sha256_of "$d/scripts/h5-source-check.sh")"
  cat >"$d/scripts/h5-admission-check.source" <<EOF
# vendor 元の記録。scripts/h5-source-check.sh がこの値と実物を照合する。
role=${3:-vendor}
source=Cor-Incorporated/claude-code-skills
ref=develop
commit=0000000000000000000000000000000000000000
sha256=$s
sha256:scripts/h5-source-check.sh=$cs
EOF
  printf '%s' "$d"
}

run_check() { # <fixture> <mode>
  set +e
  OUT="$(H5_SOURCE_ROOT="$1" bash "$CHECKER" "$2" 2>&1)"
  RC=$?
  set -e
}

echo "== 対照: 手を触れていない vendor は offline で緑 =="
F="$(mkvendor clean)"
run_check "$F" offline
if [[ "$RC" -eq 0 ]]; then ok "無改変の vendor は exit 0"
else bad "無改変なのに緑にならない" "exit=$RC / $(printf '%s' "$OUT" | head -2)"; fi

echo "== (a) 本体を 1 バイト書き換えると offline が red =="
F="$(mkvendor tampered)"
printf '\n' >>"$F/scripts/h5-admission-check.sh"   # 改行 1 バイト追加のみ
run_check "$F" offline
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q 'actual sha256'; then
  ok "1 バイト追加で red、期待値と観測値の両方が出る (exit $RC)"
else
  bad "本体改変を検出しない" "expected exit=1 + 両方の sha; observed exit=$RC / $(printf '%s' "$OUT" | head -3)"
fi

echo "== (F3) スタンプの sha256 を 1 文字変えると offline が red =="
GOOD="$(sha256_of "$BODY_SRC")"
MUT="${GOOD:0:63}$([[ "${GOOD:63:1}" == "a" ]] && echo b || echo a)"
F="$(mkvendor stamp-mutated "$MUT")"
run_check "$F" offline
if [[ "$RC" -eq 1 ]]; then ok "スタンプ 1 文字変異で red (exit $RC)"
else bad "スタンプ変異を検出しない（照合が効いていない）" "exit=$RC"; fi

echo "== スタンプが無い vendor は red（黙って通さない）=="
F="$(mkvendor no-stamp)"
rm -f "$F/scripts/h5-admission-check.source"
run_check "$F" offline
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q 'スタンプが無い'; then
  ok "スタンプ不在は red (exit $RC)"
else bad "スタンプ不在が通ってしまう" "exit=$RC / $(printf '%s' "$OUT" | head -2)"; fi

echo "== sha256 の書式不正は red（runbook: バリデーションから失敗モードを逆算）=="
for badsha in 'ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789' 'deadbeef' '`whoami`'; do
  F="$(mkvendor "badfmt-$RANDOM" "$badsha")"
  run_check "$F" offline
  if [[ "$RC" -ne 1 ]]; then
    bad "不正な sha256 '$badsha' が red にならない" "exit=$RC"
  fi
done
ok "大文字・短すぎ・バッククォート混入はいずれも red"

echo "== (b) fetch できないとき online は緑にならない =="
# ケース b-1: gh が PATH に無い（network 不要で再現できる）
F="$(mkvendor no-gh)"
set +e
OUT="$(H5_SOURCE_ROOT="$F" PATH="/usr/bin:/bin" \
  env -u GH_TOKEN bash -c 'command -v gh >/dev/null 2>&1 && exit 99; bash "$0" online' "$CHECKER" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 99 ]]; then
  echo "  (skip b-1: この環境では /usr/bin に gh がある)"
elif [[ "$RC" -eq 2 ]] && printf '%s' "$OUT" | grep -q 'UNVERIFIED'; then
  ok "b-1 gh 不在 → exit 2 UNVERIFIED（0 ではない）"
else
  bad "b-1 gh 不在で緑になった、または想定外の exit" "expected exit=2; observed exit=$RC / $(printf '%s' "$OUT" | head -2)"
fi

# ケース b-2: 正本 repo/ref が引けない（実際の fetch 失敗経路を通す）
F="$(mkvendor bad-source)"
sed -i.bak 's#^source=.*#source=Cor-Incorporated/this-repo-does-not-exist-h5-137#' \
  "$F/scripts/h5-admission-check.source"
run_check "$F" online
if [[ "$RC" -eq 2 ]] && printf '%s' "$OUT" | grep -q 'UNVERIFIED'; then
  ok "b-2 正本を取得できない → exit 2 UNVERIFIED（0 ではない）"
elif [[ "$RC" -eq 0 ]]; then
  bad "b-2 取得できないのに緑になった（#349 の形）" "exit=$RC"
else
  bad "b-2 想定外の exit" "expected exit=2; observed exit=$RC / $(printf '%s' "$OUT" | head -2)"
fi

echo "== role の閉語彙: 未知の値を vendor と読まない =="
F="$(mkvendor role-bogus "" "SOURCE_OR_SOMETHING")"
run_check "$F" offline
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q 'role の値が不正'; then
  ok "未知の role は red (exit $RC)"
else bad "未知の role が通ってしまう" "exit=$RC / $(printf '%s' "$OUT" | head -2)"; fi

echo "== role=source に online を配線したら誤用として落ちる（緑にしない）=="
F="$(mkvendor as-source "" "source")"
run_check "$F" online
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q '照合する上流が無い'; then
  ok "正本で online を呼ぶと red (exit $RC) — 上流を見ずに緑にしない"
elif [[ "$RC" -eq 0 ]]; then
  bad "正本で online が緑になった（上流を見ていないのに緑）" "exit=$RC"
else bad "想定外の exit" "expected 1; observed $RC / $(printf '%s' "$OUT" | head -2)"; fi

echo "== role=source でも offline は意味を持つ（公開 sha と本体の照合）=="
F="$(mkvendor source-offline "" "source")"
run_check "$F" offline
if [[ "$RC" -eq 0 ]]; then ok "正本の offline は緑 (exit $RC)"
else bad "正本の offline が緑にならない" "exit=$RC"; fi
printf '\n' >>"$F/scripts/h5-admission-check.sh"
run_check "$F" offline
if [[ "$RC" -eq 1 ]]; then ok "正本でも本体を 1 バイト変えると red (exit $RC)"
else bad "正本側の offline が改変を検出しない" "exit=$RC"; fi

# ===== aidd-governance#144: 追加被覆 =====
echo "== (#144) 覆っている検査器を 1 バイト変えると offline が red =="
F="$(mkvendor cover-checker)"
printf '\n# drift\n' >>"$F/scripts/h5-source-check.sh"
run_check "$F" offline
if [[ "$RC" -eq 1 ]] \
  && printf '%s' "$OUT" | grep -q 'スタンプと一致しない: scripts/h5-source-check.sh' \
  && printf '%s' "$OUT" | grep -q 'stamp  sha256' \
  && printf '%s' "$OUT" | grep -q 'actual sha256'; then
  ok "検査器の drift を検出し、ファイル名・期待 sha・実測 sha を出す (exit $RC)"
else
  bad "検査器の drift を検出しない、または診断が足りない" "exit=$RC / $(printf '%s' "$OUT" | head -4)"
fi

echo "== (#144 / F3 片側変異) 被覆を 1 つ減らすとその drift が検出されなくなる =="
F="$(mkvendor shrink-coverage)"
# スタンプから sha256:<path>= 行を落とす = 被覆を 1 つ減らす変異
grep -v '^sha256:' "$F/scripts/h5-admission-check.source" >"$F/scripts/.stamp.tmp"
mv "$F/scripts/.stamp.tmp" "$F/scripts/h5-admission-check.source"
printf '\n# drift\n' >>"$F/scripts/h5-source-check.sh"
run_check "$F" offline
if [[ "$RC" -eq 0 ]]; then
  ok "被覆行を消すと同じ drift が素通りする（被覆が判定に効いている）"
else
  bad "変異が効いていない（被覆行を消しても red のまま = 別の理由で落ちている）" "exit=$RC / $(printf '%s' "$OUT" | head -3)"
fi

echo "== (#144) 覆っているファイルが存在しないと red（黙って被覆を失わない）=="
F="$(mkvendor missing-covered)"
rm -f "$F/scripts/h5-source-check.sh"
run_check "$F" offline
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q '覆うファイルが存在しない'; then
  ok "被覆対象が消えていれば red (exit $RC)"
else bad "被覆対象の不在が素通りする" "exit=$RC / $(printf '%s' "$OUT" | head -2)"; fi

echo "== (#144) 後方互換: 旧書式スタンプ（sha256:<path> なし）でも動く =="
F="$(mkvendor legacy-stamp)"
grep -v '^sha256:' "$F/scripts/h5-admission-check.source" >"$F/scripts/.stamp.tmp"
mv "$F/scripts/.stamp.tmp" "$F/scripts/h5-admission-check.source"
run_check "$F" offline
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep -q '被覆 1 ファイル'; then
  ok "旧書式は被覆 1 ファイルとして通る（移行期に required check を止めない）"
else bad "旧書式スタンプが壊れる（移行期に全 PR が止まる）" "exit=$RC / $(printf '%s' "$OUT" | head -3)"; fi

echo "== (#144) 被覆件数が出力に出る（黙って縮まない）=="
F="$(mkvendor coverage-count)"
run_check "$F" offline
if printf '%s' "$OUT" | grep -q '被覆 2 ファイル' && printf '%s' "$OUT" | grep -q 'covered: scripts/h5-source-check.sh'; then
  ok "被覆件数と対象パスを毎回出力する"
else bad "被覆が出力から読めない" "$(printf '%s' "$OUT" | head -3)"; fi

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
