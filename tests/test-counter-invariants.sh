#!/usr/bin/env bash
# T12-3: 計数器の陰性テスト（回帰固定）
# count-c11-pr-templates.sh と ledger-summary.sh を fake HOME + fake gh で検証する。
#
# 回帰対象バグ（Phase 11 で発見）: git log --since はマッチなしでも exit 0 を返すため、
# 90 日 commit の無いリポが active90 として誤カウントされていた。
# バグ版スクリプトでは本テストが red になる（git show <修正前> で確認）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNTER="${AIDD_COUNTER_PATH:-$ROOT/scripts/count-c11-pr-templates.sh}"
SUMMARY="$ROOT/scripts/ledger-summary.sh"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

# ---- fake HOME: 3 リポ（repoA=90日commitあり / repoB=commitなし / repoC=90日commitあり・大文字テンプレ） ----
mkrepo() {  # $1=path $2=days-ago $3=template-name
  local path="$1" days="$2" tmpl="$3"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.email t@e.com
  git -C "$path" config user.name t
  git -C "$path" config commit.gpgsign false
  echo x >"$path/f"
  git -C "$path" add f
  GIT_AUTHOR_DATE="$(date -v-"$days"d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "$days days ago" +%Y-%m-%dT%H:%M:%S)" \
    GIT_COMMITTER_DATE="$(date -v-"$days"d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "$days days ago" +%Y-%m-%dT%H:%M:%S)" \
    git -C "$path" commit -q -m i
  mkdir -p "$path/.github"
  printf '## 実環境貫通（C11）\n' >"$path/.github/$tmpl"
}

mkrepo "$SB/Developer/repoA" 1 "pull_request_template.md"     # 90日commitあり・小文字
mkrepo "$SB/Developer/repoB" 1 "pull_request_template.md"     # 90日commitあり（下で commit を消す）
mkrepo "$SB/Developer/repoC" 1 "PULL_REQUEST_TEMPLATE.md"     # 90日commitあり・大文字のみ

# repoB を「90日 commit なし」にする: コミット日を 200 日前に書き換え
GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
  git -C "$SB/Developer/repoB" commit --amend -q --no-edit --date="2026-01-01T00:00:00" 2>/dev/null || true

# ---- fake gh: repo list 3 リポ / api は default_branch=main + テンプレ内容 ----
# base64 はヒアドキュメント展開で埋め込めない（引用符付き EOF）ため環境変数経由
export FAKE_C11_B64="$(printf '## 実環境貫通（C11）\n' | base64)"
mkdir -p "$SB/bin"
cat >"$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "list" ]; then
  # counter は --json name --jq '.[].name' を渡す — 名前だけ返す（fake は jq を実装しない）
  printf 'repoA\nrepoB\nrepoC\n'
  exit 0
fi
if [ "$1" = "api" ]; then
  case "$2" in
    *"contents/.github"*)
      body="{\"content\":\"$FAKE_C11_B64\"}" ;;
    *)
      body='{"default_branch":"main"}' ;;
  esac
  # counter は --jq を渡す — real gh と同様に処理する
  if [[ "$*" == *"--jq"* ]]; then
    jq_expr="${@: -1}"
    echo "$body" | jq -r "$jq_expr"
  else
    echo "$body"
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$SB/bin/gh"

# ---- 軸: 90日commit あり/なし × テンプレあり/なし × 大文字/小文字 × Cor ----
# 正しい計数: repoA(小文字) + repoC(大文字) = 2。repoB は 90日 commit なし → 除外。
if [[ "${TEST_DEBUG:-0}" -eq 1 ]]; then
  echo "DEBUG fake gh repo list: $(env PATH="$SB/bin:$PATH" gh repo list Cor-Incorporated 2>&1 | tr '\n' ',')"
  echo "DEBUG fake gh api dbr: $(env PATH="$SB/bin:$PATH" gh api "repos/Cor-Incorporated/repoA" --jq '.default_branch' 2>&1)"
  echo "DEBUG fake gh api content: $(env PATH="$SB/bin:$PATH" gh api "repos/Cor-Incorporated/repoA/contents/.github/pull_request_template.md?ref=main" --jq '.content' 2>&1 | head -c 60)"
  echo "DEBUG active90 repoB: $(git -C "$SB/Developer/repoB" log -1 --format=%ct --since="90 days ago" 2>/dev/null || echo EMPTY)"
fi
out=$(env HOME="$SB" PATH="$SB/bin:$PATH" bash "$COUNTER" --scope=active90 --branch=default)
if echo "$out" | grep -q "C11_landed=2"; then
  ok "counter active90: repoA+repoC=2 (got: $(echo "$out" | grep C11_landed))"
else
  bad "counter active90 expected 2, got: $out"
fi

# テンプレあり/なし: repoC を大文字のみ・repoA を小文字のみで両対応を確認
if echo "$out" | grep -q "case=both-cases"; then
  ok "counter both-cases mode active"
else
  bad "counter both-cases mode missing: $out"
fi

# ---- ledger-summary.sh: source 別件数 ----
LED="$SB/ledger.jsonl"
printf '{"ts":"2026-08-12T00:00:00Z","component":"H6","source":"real","hook":"a"}\n' >>"$LED"
printf '{"ts":"2026-08-12T00:00:00Z","component":"H6","source":"test","hook":"b"}\n' >>"$LED"
printf '{"ts":"2026-08-12T00:00:00Z","component":"H6","hook":"c"}\n' >>"$LED"   # source なし
printf '{"ts":"2026-08-12T00:00:01Z","component":"H6","source":"real","hook":"d"}\n' >>"$LED"
printf '{"ts":"2026-08-12T00:00:01Z","component":"H6","source":"real","hook":"e"}\n' >>"$LED"
printf '{"ts":"2026-08-12T00:00:01Z","component":"H6","source":"real","hook":"f"}\n' >>"$LED"

TP1="$SB/guardrail-fires-a.jsonl"
TP2="$SB/guardrail-fires-b.jsonl"
printf '{"schema_version":"guardrail-fire.v1","ts":"2026-08-12T00:00:02Z","rule_id":"RUNTIME_FLOOR:secret-read","decision":"deny"}\n' >"$TP1"
printf '{"schema_version":"guardrail-fire.v1","ts":"2026-08-12T00:00:03Z","rule_id":"RUNTIME_FLOOR:egress","decision":"deny"}\n' >"$TP2"
printf '{"schema_version":"unrelated.v1","ts":"2026-08-12T00:00:04Z"}\n' >>"$TP2"

sout=$(env AIDD_LEDGER_PATH="$LED" AIDD_THIRD_PARTY_LEDGER_PATHS="$TP1:$TP2:$TP1" bash "$SUMMARY")
for want in "total=6" "source_real=4" "source_test=1" "source_none=1" \
  "source_third_party=2" "total_with_third_party=8" "third_party_files=2"; do
  if echo "$sout" | grep -q "$want"; then
    ok "ledger-summary $want"
  else
    bad "ledger-summary missing $want in: $sout"
  fi
done

echo "--- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
