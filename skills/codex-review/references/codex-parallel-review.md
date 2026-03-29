# Codex 並列レビュー実行ガイド（CLI版）

Codex モード時に複数のエキスパートを CLI (`codex exec`) 経由で並列呼び出しするオーケストレーション手順。

> **重要**: Codex MCP (`mcp__codex__*`) は `block-codex-mcp.sh` によりブロックされます。
> 並列実行は Bash バックグラウンドジョブ (`&` + `wait`) で実現します。
> Ref: delegation.md, ADR-004, Issue #72, Issue #197

## 並列実行の安全性（ADR-004 との整合）

ADR-004 は「Max 1 concurrent Codex request from Claude Code」と規定しているが、
これは **Route C（実装委任・workspace-write sandbox・worktree 使用）** に対するルール。

並列エキスパートレビューは以下の理由で安全:

| 項目 | Route C（実装） | 並列レビュー |
|------|----------------|-------------|
| sandbox | workspace-write | **read-only** |
| worktree | 作成する（コンフリクトリスク） | **使用しない** |
| ファイル書き込み | あり | **なし** |
| ADR-004 制限 | 1並列 | **制限なし**（read-only） |

**結論**: `codex exec --sandbox read-only` は独立したAPIクエリとして動作し、
worktree もファイル書き込みも行わないため、複数プロセスの同時実行は安全。
ただし OpenAI API のレート制限に注意し、同時実行は最大4プロセスを推奨。

## 概要

Codex モードでは、Claude がオーケストレーターとして **4 つのエキスパート** を CLI 経由で並列呼び出しします。レビュータイプに応じて異なるエキスパートが使用されます。

## レビュータイプと4つのエキスパート

| Review Type | 4 Experts | Expert Files |
|-------------|-----------|--------------|
| **Code** | Security, Performance, Quality, Accessibility | `security-expert.md`, `performance-expert.md`, `quality-expert.md`, `accessibility-expert.md` |
| **Plan** | Clarity, Feasibility, Dependencies, Acceptance | `clarity-expert.md`, `feasibility-expert.md`, `dependencies-expert.md`, `acceptance-expert.md` |
| **Scope** | Scope-creep, Priority, Feasibility, Impact | `scope-creep-expert.md`, `priority-expert.md`, `scope-feasibility-expert.md`, `impact-expert.md` |

```
Claude (オーケストレーター)
    ↓
レビュータイプ判定
    ↓
Bash 並列 CLI 実行 (codex exec × N experts)
    ├── Expert 1 (background)
    ├── Expert 2 (background)
    ├── Expert 3 (background)
    └── Expert 4 (background)
    ↓ wait
結果統合 → 判定
```

---

## 並列呼び出し必須ルール（MANDATORY）

### 禁止事項

| 禁止 | 理由 |
|------|------|
| ❌ `mcp__codex__codex` を使用する | `block-codex-mcp.sh` でブロックされる |
| ❌ 1回の CLI 呼び出しで複数エキスパートをまとめる | 各エキスパートの専門性が薄まる |
| ❌ experts/*.md を読まずに汎用プロンプトを送る | 専門家プロンプトの知見が活かされない |

### 必須事項

| 必須 | 方法 |
|------|------|
| ✅ `codex exec` CLI を使用する | MCP ではなく CLI 経由 |
| ✅ 各エキスパートを **個別の CLI 呼び出し** で実行 | `codex exec` をレビュータイプに応じて4回呼び出し |
| ✅ experts/*.md から **個別にプロンプトを読み込む** | ファイルごとに別プロセスで実行 |
| ✅ **Bash バックグラウンドジョブで並列実行** | `&` + `wait` で並列化 |

### 正しい実行パターン

```bash
# 各エキスパートを個別に並列実行
codex exec --sandbox read-only -o /tmp/review-security.md \
  "$(cat experts/security-expert.md)" &
PID1=$!

codex exec --sandbox read-only -o /tmp/review-performance.md \
  "$(cat experts/performance-expert.md)" &
PID2=$!

codex exec --sandbox read-only -o /tmp/review-quality.md \
  "$(cat experts/quality-expert.md)" &
PID3=$!

codex exec --sandbox read-only -o /tmp/review-accessibility.md \
  "$(cat experts/accessibility-expert.md)" &
PID4=$!

# 全エキスパートの完了を待機
wait $PID1 $PID2 $PID3 $PID4
```

### なぜ分けるのか

| 1回でまとめた場合 | 4回に分けた場合 |
|------------------|-----------------|
| 各観点が2-3行で浅い | 各観点が詳細に分析される |
| 重要な問題を見落とす | 専門家視点で漏れなく検出 |
| 「問題なし」で終わりやすい | 具体的な改善提案が出る |

---

## 実行フロー

### Step 1: 設定確認

```yaml
# .claude-code-harness.config.yaml
review:
  mode: codex
  codex:
    enabled: true
    execution_mode: exec   # CLI固定（MCP廃止）
    code_experts:
      security: true
      accessibility: true
      performance: true
      quality: true
```

### Step 2: 変更ファイルの収集

```bash
git diff --name-only HEAD~1
```

### Step 3: エキスパート判定（フィルタリング）

設定で `false` のエキスパートは除外。プロジェクト種別により自動除外:

| プロジェクト種別 | 自動除外 |
|-----------------|---------|
| CLI / バックエンドAPI | Accessibility, SEO |
| Webフロントエンド | （全て有効） |
| ドキュメントのみ | Security, Performance, Accessibility |

### Step 4: プロンプト準備

`experts/*.md` から読み込み、変数を展開:

| 変数 | 取得方法 |
|------|----------|
| `{files}` | `git diff --name-only HEAD~1` |
| `{tech_stack}` | package.json から検出 |

差分コンテキストも注入:

```bash
for file in $(git diff --name-only HEAD~1); do
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
    local output_file="${OUTPUT_DIR}/${name}.md"
    codex exec \
        -C "$REPO_PATH" \
        --sandbox read-only \
        -o "$output_file" \
        "$(cat "$prompt_file")" 2>/dev/null
    echo "[${name}] Done → ${output_file}"
}

run_expert "security" "experts/security-expert.md" &
run_expert "performance" "experts/performance-expert.md" &
run_expert "quality" "experts/quality-expert.md" &
run_expert "accessibility" "experts/accessibility-expert.md" &

wait
echo "All experts completed. Results in: ${OUTPUT_DIR}/"
```

### Step 5.1: 出力制限ルール

| 制約 | 内容 |
|------|------|
| 言語 | English only（統合時に日本語化） |
| 最大文字数 | 2500 文字 |
| スコア | A-F |
| 件数 | Critical/High: 全件、Medium: 5件、Low: 3件 |

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

## MCP からの移行

| 旧（MCP・廃止） | 新（CLI） |
|-----------------|-----------|
| `mcp__codex__codex({prompt: ...})` | `codex exec --sandbox read-only "..."` |
| Claude 並列ツール呼び出し | Bash `&` + `wait` |
| MCP サーバー登録必要 | CLI のみ、登録不要 |

## 並列実行上の注意

- **API レート制限**: OpenAI API のレート制限により、同時4プロセスを超える並列は推奨しない
- **Route C との区別**: 実装委任（Route C）は ADR-004 により1並列。レビュー（read-only）は並列可
- **codex-parallel.sh --review（Route A）**: 単一プロセスで実行。並列エキスパートレビューとは別経路
- **コスト**: 4並列 = 4倍のAPIコール。必要なエキスパートのみ有効化してコスト最適化

> Ref: Issue #197, delegation.md, ADR-004
