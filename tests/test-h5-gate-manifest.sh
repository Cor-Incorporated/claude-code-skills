#!/usr/bin/env bash
# .aidd-h5-gates（宣言）↔ h5-admission-check.sh の h5_*_gate（強制）の pair テスト。
# aidd-governance#137 — 単一正本 + vendoring における「どのゲートが有効か」の強制点。
#
# 本テストが押さえる反証:
#   (1) on と宣言したのに requires のファイルが無い → red
#       = 「宣言ファイルを持たないゲートを有効と数えない」(#137 の D2 に対する強制)
#   (2) off と宣言 → ゲートは呼ばれず、skip したことが出力に出る（黙って緑にしない）
#   (3) マニフェストからゲートを 1 行消す（F3 片側変異）→ 宣言漏れが出力に出る
#   (4) マニフェスト自体が無い → 従来の自己検出へ落ちる（フリート後方互換）
#   (5) 宣言側と強制側の全件照合（片側だけ足りなければ両方の値を挙げて落ちる）
set -euo pipefail
export AIDD_LEDGER_SOURCE=test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$ROOT/scripts/h5-admission-check.sh"
GATES="$ROOT/.aidd-h5-gates"
unset H5_PR_NUMBER GITHUB_EVENT_PATH
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "  $2"; fail=$((fail + 1)); }

# 判定に使う最小の fixture repo を作る。ROOT はスクリプトの親なので
# <fixture>/scripts/h5-admission-check.sh へ置けば <fixture> が ROOT になる。
mkfixture() { # <name> <gates-file-content|__none__> -> fixture root
  # local は引数を先に展開するため、同一文で $name を参照すると set -u で落ちる。
  local name="$1" gates="$2" d
  d="$WORK/$name"
  mkdir -p "$d/scripts" "$d/design/ops"
  cp "$CHK" "$d/scripts/h5-admission-check.sh"
  [[ "$gates" == "__none__" ]] || printf '%s\n' "$gates" >"$d/.aidd-h5-gates"
  printf '%s\n' "" >"$d/design/ops/protected-identity-paths.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$d/scripts/repair-loop-breaker.sh"
  printf '%s' "$d"
}

run_fixture() { # <fixture> <diff> <body> -> stdout+stderr; sets RC
  local d="$1" diff="$2" body="$3"
  set +e
  OUT="$(H5_DIFF_FILES="$diff" H5_PR_BODY="$body" H5_LEDGER_PATH="$WORK/ledger.jsonl" \
      H5_REPAIR_THRESHOLD=999999 bash "$d/scripts/h5-admission-check.sh" 2>&1)"
  RC=$?
  set -e
}

echo "== (1) on と宣言したのに requires のファイルが無い → red =="
F="$(mkfixture missing-decl 'acl-change on requires=design/ops/protected-identity-paths.txt
repair-family on requires=scripts/repair-loop-breaker.sh
h8-identifier-scope on')"
rm -f "$F/design/ops/protected-identity-paths.txt"   # 宣言ファイルだけ消す
run_fixture "$F" "docs/foo.md" "H5-E2E: none"
if [[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep -q 'protected-identity-paths.txt'; then
  ok "宣言ファイルを消すと acl-change が有効と数えられない (exit $RC)"
else
  bad "宣言ファイル欠落が red にならない" "expected exit=1 + missing 行; observed exit=$RC / $(printf '%s' "$OUT" | head -2)"
fi

echo "== (2) off と宣言 → ゲートを呼ばず、skip が出力に出る =="
F="$(mkfixture gate-off 'acl-change off reason=保護パス宣言をまだ持たない
repair-family off reason=repair-loop-breaker.sh を持たない
h8-identifier-scope on')"
rm -f "$F/design/ops/protected-identity-paths.txt" "$F/scripts/repair-loop-breaker.sh"
run_fixture "$F" "docs/foo.md" "H5-E2E: none"
if [[ "$RC" -eq 0 ]] \
  && printf '%s' "$OUT" | grep -q 'H5-GATES-SKIP: acl-change' \
  && printf '%s' "$OUT" | grep -q 'H5-GATES-SKIP: repair-family'; then
  ok "off 宣言でゲートを呼ばず、skip 2 件が出力に出る (exit $RC)"
else
  bad "off 宣言が正しく skip されない" "observed exit=$RC / $(printf '%s' "$OUT" | grep -c 'H5-GATES-SKIP') skip lines"
fi

echo "== (3) F3 片側変異: マニフェストから 1 行消す → 宣言漏れが出る =="
F="$(mkfixture missing-row 'repair-family on requires=scripts/repair-loop-breaker.sh
h8-identifier-scope on')"   # acl-change の行だけ無い
run_fixture "$F" "docs/foo.md" "H5-E2E: none"
if printf '%s' "$OUT" | grep -q 'acl-change が .* に宣言されていない'; then
  ok "マニフェストの行を消すと宣言漏れが出力に出る"
else
  bad "宣言漏れが観測できない（マニフェストが判定に効いていない）" "observed: $(printf '%s' "$OUT" | head -3)"
fi

echo "== (4) マニフェスト自体が無い → 従来の自己検出へ落ちる（後方互換）=="
F="$(mkfixture no-manifest __none__)"
run_fixture "$F" "docs/foo.md" "H5-E2E: none"
if [[ "$RC" -eq 0 ]] && ! printf '%s' "$OUT" | grep -q 'H5-GATES-SKIP'; then
  ok "マニフェスト不在でも従来どおり動く (exit $RC) — フリートの旧版を壊さない"
else
  bad "マニフェスト不在で挙動が変わった" "observed exit=$RC / $(printf '%s' "$OUT" | head -2)"
fi

echo "== (5) 宣言側 ↔ 強制側の全件照合 =="
# 強制側: 本体が定義する h5_<name>_gate 関数（h8-identifier-scope は配列駆動なので別途）
# h5_run_gate / h5_gate_enabled / h5_gate_line はマニフェスト機構そのものなので除く。
# ゲート本体だけを拾う（h5_<name>_gate の形で、かつ機構側の名前でないもの）。
enforced="$(grep -oE '^h5_[a-z_]+_gate\(\)' "$CHK" \
  | sed -E 's/^h5_(.*)_gate\(\)$/\1/' \
  | grep -vxE 'run' \
  | tr '_' '-' | sort -u)"
enforced="$(printf '%s\nh8-identifier-scope\n' "$enforced" | grep -v '^$' | sort -u)"
declared="$(grep -vE '^[[:space:]]*(#|$)' "$GATES" | awk '{print $1}' | sort -u)"
if [[ "$enforced" == "$declared" ]]; then
  ok "宣言 $(printf '%s\n' "$declared" | wc -l | tr -d ' ') 件 == 強制 $(printf '%s\n' "$enforced" | wc -l | tr -d ' ') 件"
else
  # runbook.md rule B: 両方の値を挙げて落ちる。「不一致」だけでは直せない。
  bad "宣言側と強制側が食い違っている" "enforced=[$(printf '%s' "$enforced" | tr '\n' ' ')] declared=[$(printf '%s' "$declared" | tr '\n' ' ')]"
fi

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
