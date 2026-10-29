#!/usr/bin/env bash
# NEGATIVE-TEST-FOR: hooks/post-deploy-verify.sh
# post-deploy-verify.sh は「実行されたデプロイ」にだけチェックリストを出す。
#
# 起点 (2026-10-30 harness-pdca): README を書き換える python heredoc の本文に
# `gcloud run deploy` / `docker push` の文字があっただけで DEPLOYMENT DETECTED が出た。
# grep で文書を探すだけのコマンドでも同じ。毎回出る警告は読まれなくなる。
#
# 反証可能性: HOOK=<旧版> で流すと heredoc と grep の 2 件が red になる。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK:-$ROOT/hooks/post-deploy-verify.sh}"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; echo "    $2"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/hooks/lib"
cp "$HOOK" "$SB/hooks/post-deploy-verify.sh"
cp "$ROOT/hooks/lib/aidd-ledger.sh" "$SB/hooks/lib/aidd-ledger.sh"

fires() { # $1 = command → prints "fire" or "silent"
  local out
  out="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" \
    | HOME="$SB" AIDD_LEDGER_SOURCE=test bash "$SB/hooks/post-deploy-verify.sh" 2>/dev/null)"
  [[ "$out" == *"DEPLOYMENT DETECTED"* ]] && echo fire || echo silent
}

expect() { # $1 = name, $2 = command, $3 = fire|silent
  local got
  got="$(fires "$2")"
  [[ "$got" == "$3" ]] && ok "$1" || bad "$1" "want $3, got $got: $2"
}

NL=$'\n'
expect "a Cloud Run deploy fires" "gcloud run deploy api --region asia-northeast1 --image x" fire
expect "docker push after cd && fires" "cd app && docker push gcr.io/p/i:1" fire
expect "kubectl apply behind an env assignment fires" "KUBECONFIG=k.yaml kubectl apply -f d.yaml" fire
expect "a deploy inside \$( ) fires" 'out=$(gcloud run deploy api --source .)' fire
expect "a heredoc body that mentions a deploy is silent" \
  "python3 - <<'EOF'${NL}s = 'after gcloud run deploy or docker push, verify'${NL}EOF" silent
expect "grepping docs for the words is silent" "grep -n 'docker push' README.md" silent
expect "echoing the words is silent" 'echo "next: kubectl apply -f x"' silent
expect "a command after the heredoc still fires" \
  "cat > notes.md <<'EOF'${NL}text${NL}EOF${NL}docker push gcr.io/p/i:2" fire
# #445 review: a command-position rule missed these real deploys
expect "for … do docker push fires" 'for t in a b; do docker push img:$t; done' fire
expect "then gcloud run deploy fires" "if true; then gcloud run deploy api --image x; fi" fire
expect "timeout 900 gcloud run deploy fires" "timeout 900 gcloud run deploy api" fire
expect "sudo -E docker push fires" "sudo -E docker push img:1" fire
expect "{ docker push; } fires" "{ docker push x; }" fire
expect "xargs docker push fires" "xargs -n1 docker push" fire
expect "bash -c \"kubectl apply\" fires" 'bash -c "kubectl apply -f d.yaml"' fire
expect "a here-string is not a heredoc" "grep -q x <<< foo${NL}docker push x" fire
expect "an arithmetic shift is not a heredoc" 'echo $((1<<n))'"${NL}docker push x" fire
expect "a non-deploy command is silent" "ls -la && git status" silent

# --- 変異体: heredoc bodies not skipped ---
# 同じ表をこの変異体に流し、少なくとも 1 件 red になることを実測する。
if [[ -z "${IN_MUTANT:-}" ]]; then
  MUT="$SB/mutant-hook.sh"
  python3 - "$HOOK" "$MUT" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = '    if term is not None:'
assert old in src, "mutation anchor not found"
open(sys.argv[2], "w").write(src.replace(old, '    if False:', 1))
PY
  if [[ ! -s "$MUT" ]] || cmp -s "$HOOK" "$MUT"; then
    bad "mutation could not be applied" "anchor not found in $HOOK — update the mutant"
  elif IN_MUTANT=1 HOOK="$MUT" bash "$0" >/dev/null 2>&1; then
    bad "mutant (heredoc bodies not skipped) stays green" "the table above does not detect it"
  else
    ok "mutant (heredoc bodies not skipped) goes red"
  fi
fi

echo "---"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
