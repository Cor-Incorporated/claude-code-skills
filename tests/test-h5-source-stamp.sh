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
mkvendor() { # <name> [sha-override] -> fixture root
  local name="$1" override="${2:-}" d s
  d="$WORK/$name"
  mkdir -p "$d/scripts"
  cp "$BODY_SRC" "$d/scripts/h5-admission-check.sh"
  s="$(sha256_of "$d/scripts/h5-admission-check.sh")"
  [[ -n "$override" ]] && s="$override"
  cat >"$d/scripts/h5-admission-check.source" <<EOF
# vendor 元の記録。scripts/h5-source-check.sh がこの値と本体を照合する。
source=Cor-Incorporated/aidd-governance
ref=main
commit=0000000000000000000000000000000000000000
sha256=$s
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

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
