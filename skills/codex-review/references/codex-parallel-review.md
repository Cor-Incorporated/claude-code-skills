# Codex 並列レビュー実行ガイド（CLI版）

複数のエキスパートを `codex exec --sandbox read-only` で並列呼び出しするオーケストレーション手順。

> **重要**: Codex MCP (`mcp__codex__*`) は使用禁止（運用ルール）。旧 `block-codex-mcp.sh` hook は `hooks/_unused/` へ退避済みで現在は発火しないため、hook 強制ではなく自己規律で遵守する。
> Ref: delegation.md, ADR-004, Issue #72, Issue #197

## 並列実行の安全性（ADR-004 との整合）

ADR-004「Max 1 concurrent Codex request」は **Route C（実装・workspace-write・worktree 使用）** に対するルール。

| 項目 | Route C（実装） | 並列レビュー |
|------|----------------|-------------|
| sandbox | workspace-write | **read-only** |
| worktree | 作成（コンフリクトリスク） | **不使用** |
| ファイル書き込み | あり | **なし** |
| ADR-004 制限 | 1並列 | **制限なし** |

`codex exec --sandbox read-only` は独立 API クエリとして動作し、
worktree もファイル書き込みも行わないため並列安全。
API レート制限を考慮し同時最大4プロセスを推奨。

> **TODO**: この解釈は ADR-004 amendment で正式に明文化すべき。

## 概要

Claude がオーケストレーターとして **4 つのエキスパート** を CLI 並列呼び出し。

```
Claude (オーケストレーター)
    ↓ レビュータイプ判定
    ↓ Bash 並列 (codex exec × N)
    ├── Expert 1 &
    ├── Expert 2 &
    ├── Expert 3 &
    └── Expert 4 &
    ↓ wait
結果統合 → 判定
```

## レビュータイプとエキスパート

| Type | 4 Experts |
|------|-----------|
| **Code** | Security, Performance, Quality, Accessibility |
| **Plan** | Clarity, Feasibility, Dependencies, Acceptance |
| **Scope** | Scope-creep, Priority, Feasibility, Impact |

> `experts/*.md` プロンプトファイルはハーネスプラグインが提供。
> 未設定時はプロジェクト固有のプロンプトを `skills/codex-review/experts/` に作成すること。

---

## 必須ルール

### 禁止

| 禁止 | 理由 |
|------|------|
| `mcp__codex__codex` を使用 | 禁止（運用ルール。旧 `block-codex-mcp.sh` hook は退避済みで現在は不発火）|
| 1回で複数エキスパートをまとめる | 専門性が薄まる |
| experts/*.md を読まずに汎用プロンプト | 専門知見が活かされない |

### 正しい実行パターン

```bash
REPO="$(pwd)"

# stdout キャプチャで完全な出力を取得
# Note: -o (--output-last-message) は最後のメッセージのみ。
#       完全な出力には stdout リダイレクトを使用。
codex exec -C "$REPO" --sandbox read-only \
  "$(cat experts/security-expert.md)" > /tmp/review-security.md 2>/dev/null &
PID1=$!

codex exec -C "$REPO" --sandbox read-only \
  "$(cat experts/performance-expert.md)" > /tmp/review-perf.md 2>/dev/null &
PID2=$!

codex exec -C "$REPO" --sandbox read-only \
  "$(cat experts/quality-expert.md)" > /tmp/review-quality.md 2>/dev/null &
PID3=$!

codex exec -C "$REPO" --sandbox read-only \
  "$(cat experts/accessibility-expert.md)" > /tmp/review-a11y.md 2>/dev/null &
PID4=$!

wait $PID1 $PID2 $PID3 $PID4
```

---

## 実行フロー

### Step 1: 設定確認

```yaml
# .claude-code-harness.config.yaml（ハーネスプラグインの設定ファイル）
review:
  codex:
    enabled: true
    code_experts:
      security: true
      accessibility: true
      performance: true
      quality: true
```

### Step 2: 変更ファイル収集

```bash
git diff --name-only HEAD~1
```

### Step 3: エキスパート判定

設定で `false` は除外。プロジェクト種別で自動除外:

| 種別 | 除外 |
|------|------|
| CLI / バックエンド | Accessibility, SEO |
| Webフロントエンド | なし |
| ドキュメントのみ | Security, Performance, Accessibility |

### Step 4: プロンプト準備

差分コンテキストを注入:

```bash
git diff -z --name-only HEAD~1 | while IFS= read -r -d '' file; do
  echo "=== $file ==="
  git diff HEAD~1 -- "$file" | head -200
done
```

### Step 5: CLI 並列実行

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_PATH="$(pwd)"
OUTPUT_DIR="/tmp/codex-review-$(date +%s)"
mkdir -p "$OUTPUT_DIR"

run_expert() {
    local name="$1"
    local prompt_file="$2"
    codex exec \
        -C "$REPO_PATH" \
        --sandbox read-only \
        "$(cat "$prompt_file")" > "${OUTPUT_DIR}/${name}.md" 2>/dev/null
    echo "[${name}] Done"
}

run_expert "security" "experts/security-expert.md" &
run_expert "performance" "experts/performance-expert.md" &
run_expert "quality" "experts/quality-expert.md" &
run_expert "accessibility" "experts/accessibility-expert.md" &

wait
echo "Results in: ${OUTPUT_DIR}/"
```

### Step 6: 結果統合

```markdown
## Codex 並列レビュー結果

| Expert | Score | Critical | High | Medium | Low |
|--------|-------|----------|------|--------|-----|
| Security | B | 0 | 1 | 2 | 3 |
| Performance | C | 0 | 2 | 3 | 1 |
| Quality | B | 0 | 0 | 4 | 5 |
| Accessibility | A | 0 | 0 | 1 | 2 |
```

### Step 7: コミット判定

| 集計 | 判定 | アクション |
|------|------|-----------|
| Critical >= 1 | REJECT | 手動介入必須 |
| High >= 1 | REQUEST CHANGES | 自動修正ループ（最大3回） |
| Critical = 0, High = 0 | APPROVE | コミット可能 |

> Low/Medium のみは APPROVE（重箱の隅つつき防止）。

---

## エラーハンドリング

一部エキスパート失敗時は成功分で判定続行。全失敗時は Claude 単体レビューにフォールバック。

## 出力制限ルール

| 制約 | 内容 |
|------|------|
| 言語 | English only（統合時に日本語化） |
| 最大文字数 | 2500 文字 |
| スコア | A-F |
| 件数 | Critical/High: 全件、Medium: 5件、Low: 3件 |

## MCP からの移行

| 旧（MCP・廃止） | 新（CLI） |
|-----------------|-----------|
| `mcp__codex__codex({prompt: ...})` | `codex exec --sandbox read-only "..."` |
| Claude 並列ツール呼び出し | Bash `&` + `wait` |
| MCP サーバー登録 | 不要 |

> Ref: Issue #197, delegation.md, ADR-004
