#!/bin/bash
# block-state-file-tampering-bash.sh
# PreToolUse hook: Bash経由の状態ファイル改ざんをブロック
#
# 設計原則: FAIL-CLOSED (deny by default)
# 保護対象ファイル名がコマンド全体（多行含む）に出現したら、
# 明示的にread-onlyパターンと判定されない限りブロックする。
#
# 2026-03-21: 初版（AI自己バイパス防止）
# 2026-03-25: インシデント — CMD_FIRST_LINE のみチェックで多行python3 -c バイパス
# 2026-03-26: Issue #157 修正 — CMD全体スキャン + fail-closed化
#
# バイパス防止の構造:
#   1. CMD全体（多行）をスキャン → 1行目だけでは逃げられない
#   2. read-only allowlist AND write-pattern否定の両方を満たさないと許可しない
#   3. 不明なパターンはブロック（fail-closed）

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# 空コマンドは無関係 — 即許可
if [[ -z "$CMD" ]]; then
  exit 0
fi

# 保護対象のファイル名パターン
PROTECTED="review-status\.json|pr-review-lock\.json|pr-review-read\.json|context-budget\.json|factcheck-status\.json|rebase-session\.json|pr-gate-diagnostic\.log"

# コマンド全体（多行含む）で保護対象ファイルを検出
if echo "$CMD" | grep -qE "$PROTECTED"; then

  # --- 書き込みパターン（広範に検出） ---
  WRITE_PATTERNS='(>|>>|json\.dump|json\.dumps|echo\s.*>|printf\s.*>|tee\s|sponge\s|sed\s+-i|write_text|open\s*\(.*["\x27]w|open\s*\(.*["\x27]a|\.write\s*\(|Path\s*\(.*write_|truncate|dd\s+of=|cp\s+.*\.(json|log)|mv\s+.*\.(json|log)|ln\s+-[sf]|eval\s|exec\s+[0-9]*>|curl\s.*-o|wget\s.*-O|ruby\s+-e|perl\s+-e|perl\s+-i|node\s+-e|deno\s+(eval|run)|php\s+-r)'

  # --- read-only allowlistパターン ---
  # 単純な読み取りコマンドのみ許可（1行コマンド限定）
  # 多行コマンドはread-onlyと見なさない（書き込みを隠せるため）
  MULTILINE="false"
  LINE_COUNT=$(echo "$CMD" | wc -l | tr -d ' ')
  if [[ "$LINE_COUNT" -gt 1 ]]; then
    MULTILINE="true"
  fi

  READ_ONLY_PATTERNS='^\s*(cat|jq(\s+-[re]+)*|less|head|tail|wc|file|stat|md5sum|sha256sum|diff|git|gh|grep|rg|find|which|type|command|test)\s'

  # 書き込み判定用: 既知の安全なリダイレクトのみを除去
  # 除去対象: 2>/dev/null, >/dev/null（stderr/stdout抑制）, 2>&1, 2>&2（fd複製）
  # 注意: 以前の広範パターン s/[0-9]*>[>&\/][^ ]*//g は >/absolute/path も除去し
  # cat file >/path/to/protected.json のバイパスを許していた (Codex P1)
  CMD_FOR_WRITE_CHECK=$(echo "$CMD" | sed -E 's/[0-9]*>\/dev\/null//g; s/[0-9]*>&[0-9]+//g')

  # 判定: read-only AND NOT compound AND NOT multiline AND NOT write → 許可
  # 全てのshell複合演算子 (|, ||, &&, ;) をブロック
  # パイプ/チェイン経由で任意の書き込みコマンドを隠せるため、
  # 保護ファイル検出時はsimpleコマンドのみ許可
  # AIはReadツールで状態ファイルを読めるのでBashパイプは不要
  COMPOUND_OPS='[|;]|&&|\|\|'
  if [[ "$MULTILINE" == "false" ]] && \
     ! echo "$CMD" | grep -qE "$COMPOUND_OPS" && \
     echo "$CMD" | grep -qE "$READ_ONLY_PATTERNS" && \
     ! echo "$CMD_FOR_WRITE_CHECK" | grep -qE "$WRITE_PATTERNS"; then
    exit 0
  fi

  # --- それ以外は全てブロック (fail-closed) ---
  cat >&2 <<ERRMSG

⛔ [BLOCKED] Bash経由の状態ファイル改ざんを検出

コマンド（先頭200文字）: $(echo "$CMD" | head -c 200)
多行コマンド: $MULTILINE (${LINE_COUNT}行)
理由: ゲート状態ファイルへの直接アクセスは、明示的なread-only操作以外禁止です。

正しい方法:
  - review-status.json → code-reviewer実行 → record-code-review.sh が自動更新
  - pr-review-lock.json → git push → pr-ci-review-gate.sh が自動設定
  - context-budget.json → context-budget-reset.sh がセッション開始時に初期化

📋 AI自己バイパス防止ルール (2026-03-21追加, 2026-03-26 fail-closed化)
   Issue #157: 多行コマンドによるバイパスを完全遮断

ERRMSG
  exit 2
fi

exit 0
