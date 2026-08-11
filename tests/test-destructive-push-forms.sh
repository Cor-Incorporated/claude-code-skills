#!/bin/bash
# F1 マトリクス: 破壊的 push の入力空間を軸で列挙して固定する
#
# 発端（2026-08-11 loop-break T1 follow-up）:
#   Track A T1 は「4 形が BLOCK」で完了と報告されたが、入力空間を列挙していなかった。
#   後日 18 形を列挙したところ **8 形が通過**していた。3 クラス:
#     (1) 引用形                `git push origin "--mirror"` / `'--mirror'`
#     (2) refspec force (+<ref>) `git push origin +main` — クラス丸ごと未被覆
#     (3) git グローバルオプション `git -c foo=bar push origin --mirror`
#
# 本テストは「軸 × 全組み合わせ」を固定する。protect-branches.sh の
# cmd_norm / _GIT_PUSH_RE / Check 0a / Check 0a2 を触ったら必ずこれを通すこと。
#
# 軸1: 破壊の種類 = mirror|all / refspec-force(+) / 明示 force / delete
# 軸2: 引用形     = 裸 / "..." / '...'
# 軸3: 語順       = remote 先行 / フラグ先行
# 軸4: 前置       = なし / git グローバルオプション
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/protect-branches.sh"
PASS=0; FAIL=0

# JSON 文字列としてコマンドを埋め込む（引用符を含む入力を壊さないため）
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

test_case() {
  local name="$1" expect="$2" cmd="$3"   # expect: block | allow
  local rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
    | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  local ok
  if [ "$expect" = "block" ]; then
    [ "$rc" -ne 0 ] && ok=1 || ok=0
  else
    [ "$rc" -eq 0 ] && ok=1 || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $name (rc=$rc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expect=$expect rc=$rc) :: $cmd"; FAIL=$((FAIL + 1))
  fi
}

echo "=== destructive push forms (F1 matrix) ==="

echo "--- 軸1a: mirror / all × 軸2 引用形 × 軸3 語順 ---"
test_case "mirror bare, remote first"      block 'git push origin --mirror'
test_case "mirror double-quoted"           block 'git push origin "--mirror"'
test_case "mirror single-quoted"           block "git push origin '--mirror'"
test_case "mirror flag first"              block 'git push --mirror origin'
test_case "mirror, remote quoted"          block 'git push "origin" --mirror'
test_case "mirror with trailing flag"      block 'git push origin --mirror --quiet'
test_case "all bare"                       block 'git push origin --all'
test_case "all + force"                    block 'git push --all --force origin'

echo "--- 軸1b: refspec force (+<ref>) — 2026-08-11 に発見した未被覆クラス ---"
test_case "refspec + main"                 block 'git push origin +main'
test_case "refspec + src:dst"              block 'git push origin +main:main'
test_case "refspec + develop"              block 'git push origin +develop'
test_case "refspec + quoted"               block 'git push origin "+main"'
test_case "refspec + after colon"          block 'git push origin HEAD:+main'

echo "--- 軸1c: 明示 force ---"
test_case "--force"                        block 'git push --force origin main'
test_case "-f"                             block 'git push -f origin main'
test_case "--force-with-lease"             block 'git push --force-with-lease origin main'

echo "--- 軸1d: delete ---"
test_case "--delete protected"             block 'git push origin --delete main'
test_case "colon delete protected"         block 'git push origin :main'

echo "--- 軸4: git グローバルオプション前置 ---"
test_case "git -c k=v push --mirror"       block 'git -c foo=bar push origin --mirror'
test_case "git --no-pager push +main"      block 'git --no-pager push origin +main'

echo "--- 偽陽性チェック（通過すべき） ---"
test_case "normal feature push"            allow 'git push origin feat/x'
test_case "normal push -u"                 allow 'git push -u origin docs/y'
test_case "branch name containing plus"    allow 'git push origin feat/a+b'
test_case "git status"                     allow 'git status'
test_case "git log"                        allow 'git log --oneline -5'
test_case "commit message with plus"       allow 'git commit -m "fix: a+b"'
test_case "git fetch"                      allow 'git fetch origin'

# ---------------------------------------------------------------------------
# Phase 3 T3-1: refs/heads/ 被覆（CC が Cursor/Codex と揃う）
# 軸: ref 表記 × +有無 × 保護ブランチ × -u
# protect-branches + git-push-guard の複合（設定上の PreToolUse 順と同一）
# ---------------------------------------------------------------------------
HOOK_GUARD="$SCRIPT_DIR/../hooks/git-push-guard.sh"

test_composite() {
  local name="$1" expect="$2" cmd="$3"
  local rc1=0 rc2=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
    | bash "$HOOK" >/dev/null 2>&1 || rc1=$?
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$cmd")" \
    | bash "$HOOK_GUARD" >/dev/null 2>&1 || rc2=$?
  local blocked=0
  [ "$rc1" -ne 0 ] && blocked=1
  [ "$rc2" -ne 0 ] && blocked=1
  local ok
  if [ "$expect" = "block" ]; then
    [ "$blocked" -eq 1 ] && ok=1 || ok=0
  else
    [ "$blocked" -eq 0 ] && ok=1 || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $name (rc_pb=$rc1 rc_gpg=$rc2)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expect=$expect rc_pb=$rc1 rc_gpg=$rc2) :: $cmd"; FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== Phase 3 T3-1: refs/heads/ coverage (composite protect-branches + git-push-guard) ==="
echo "--- ref 表記 × + × 保護ブランチ × -u ---"
for b in main master develop; do
  test_composite "bare $b"                    block "git push origin $b"
  test_composite "refs/heads/$b"              block "git push origin refs/heads/$b"
  test_composite "HEAD:$b"                    block "git push origin HEAD:$b"
  test_composite "HEAD:refs/heads/$b"         block "git push origin HEAD:refs/heads/$b"
  test_composite "+HEAD:$b"                   block "git push origin +HEAD:$b"
  test_composite "+refs/heads/$b"             block "git push origin +refs/heads/$b"
  test_composite "+HEAD:refs/heads/$b"        block "git push origin +HEAD:refs/heads/$b"
  test_composite "-u bare $b"                 block "git push -u origin $b"
  test_composite "-u HEAD:refs/heads/$b"      block "git push -u origin HEAD:refs/heads/$b"
  test_composite "-u refs/heads/$b"           block "git push -u origin refs/heads/$b"
done

echo "--- T3-1 偽陽性（複合） ---"
test_composite "feat/x"                       allow 'git push origin feat/x'
test_composite "feat/a+b"                     allow 'git push origin feat/a+b'
test_composite "status"                       allow 'git status'
test_composite "fetch origin"                 allow 'git fetch origin'
test_composite "HEAD:feat/x"                  allow 'git push origin HEAD:feat/x'

echo ""
echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
