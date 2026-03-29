---
name: codex-review
description: "Codexにセカンドオピニオンを求める。AI同士の忖度なしガチレビュー。Use when user mentions 'Codex レビュー', 'セカンドオピニオン', 'Codex の意見', 'Codex でレビュー', or 'Codex セットアップ'. Do NOT load for: 'Codex に実装させて', 'Codex Worker', 'Codex に作らせて', '実装を依頼'."
allowed-tools: ["Bash", "Read", "Write", "Edit"]
argument-hint: "[code|plan|scope]"
---

# Codex Review Integration Skill

OpenAI Codex CLI を使用してコードレビュー時にセカンドオピニオンを提供するスキル。

> **重要**: Codex MCP (`mcp__codex__*`) は使用禁止です（delegation.md / Issue #72）。
> 全ての Codex 呼び出しは CLI (`codex exec`) 経由で行います。
> Ref: ADR-004, `hooks/block-codex-mcp.sh`

## Do NOT Load For (誤発動防止)

以下のキーワードは `codex-worker` スキルが担当します:

| トリガーワード | 正しいスキル | 理由 |
|---------------|-------------|------|
| "Codex に実装させて" | `codex-worker` | 実装 ≠ レビュー |
| "Codex Worker" | `codex-worker` | Worker = 実装役 |
| "Codex に作らせて" | `codex-worker` | 作成 = 実装 |
| "実装を依頼" | `codex-worker` | 実装目的 |

## 使用場面

### レビュー
- **セカンドオピニオン**: Claude のレビュー結果に Codex の視点を追加
- **コード品質チェック**: 複数 AI モデルの得意分野を活用
- **設計レビュー**: アーキテクチャや実装パターンの多角的検証

## 機能詳細

| 機能 | 詳細 |
|------|------|
| **レビュー統合** | See [references/codex-review-integration.md](references/codex-review-integration.md) |
| **並列レビュー** | See [references/codex-parallel-review.md](references/codex-parallel-review.md) |

## 実行手順

1. ユーザーのリクエストを分類
2. 上記の「機能詳細」から適切な参照ファイルを読む
3. その内容に従って CLI でレビューを実行

### 並列レビュー時の必須ルール

**Codex モード（`review.mode: codex`）でのレビュー実行時**:

1. **呼び出すエキスパートを判定**（全部ではなく必要なもののみ）:
   - 設定で `enabled: false` → 除外
   - CLI/バックエンド → Accessibility, SEO 除外
   - ドキュメントのみ変更 → Quality, Architect を優先
2. 有効なエキスパートの `references/experts/*.md` から **プロンプトを個別に読み込む**
3. 有効なエキスパートのみ **Bash で codex exec を並列実行**
4. 絶対に1回の呼び出しで複数観点をまとめない

```
正しい（CLI 並列実行）:
  Bash(codex exec --sandbox read-only "$(cat experts/security-expert.md)" &)
  Bash(codex exec --sandbox read-only "$(cat experts/performance-expert.md)" &)
  Bash(codex exec --sandbox read-only "$(cat experts/quality-expert.md)" &)
  wait

間違い:
  mcp__codex__codex({prompt: "..."})  ← hookでBLOCKED
```

**詳細**: [references/codex-parallel-review.md](references/codex-parallel-review.md)

---

## 実行方法

### 単発レビュー（経路A）

```bash
# codex-parallel.sh --review を使用
bash ~/.claude/scripts/codex-parallel.sh --review "$(pwd)" --base develop
```

### 直接 CLI 呼び出し

```bash
# codex exec で直接レビュー
codex exec --sandbox read-only "以下のコードをレビューしてください: ..."
```

### 並列エキスパートレビュー

```bash
# 各エキスパートを個別に並列実行
codex exec --sandbox read-only -o /tmp/review-security.md "$SECURITY_PROMPT" &
codex exec --sandbox read-only -o /tmp/review-performance.md "$PERF_PROMPT" &
codex exec --sandbox read-only -o /tmp/review-quality.md "$QUALITY_PROMPT" &
wait
# 結果を統合
```

---

## レビューワークフロー

### Solo モード

```
/codex-review 実行
    │
    ├── Claude レビュー（従来通り）
    │
    └── codex exec CLI 呼び出し
            │
            └── 結果統合
```

### 2-Agent モード

```
PM（Cursor / Codex）
    │
    └── タスク依頼
            │
            ├── Claude Code 実装
            │
            └── /harness-review
                    │
                    ├── Claude レビュー
                    └── Codex CLI セカンドオピニオン
```

---

## 設定

`.claude-code-harness.config.yaml` で Codex 統合を設定:

```yaml
review:
  codex:
    enabled: true
    auto: false
    prompt: "Review the code and output issues and improvement suggestions"
    execution_mode: exec   # CLI直接実行（唯一のサポートモード）
```

| 設定項目 | デフォルト | 説明 |
|---------|-----------|------|
| `enabled` | `false` | Codex 統合の有効/無効 |
| `auto` | `false` | 自動レビュー実行 |
| `prompt` | (上記) | Codex へのレビュープロンプト |
| `execution_mode` | `exec` | CLI 直接実行（MCP は廃止） |

> **Note**: `execution_mode: mcp` はレガシーであり `block-codex-mcp.sh` によりブロックされます。
> 単発・並列ともに `codex exec` CLI を使用してください。

---

## 注意事項

### MCP 廃止について

- Codex MCP (`mcp__codex__*`) は `block-codex-mcp.sh` hook により PreToolUse でブロックされます
- delegation.md: "Codex MCP使用禁止 — CLI経由のみ"
- ADR-004: 3-Phase Model で Codex は CLI 経由の大規模委任に使用
- **全ての呼び出しは `codex exec` CLI で行うこと**

### 並列実行と ADR-004 の整合

ADR-004 の「Max 1 concurrent Codex request」は **Route C（実装・workspace-write）** に対するルール。
並列エキスパートレビューは `--sandbox read-only` で worktree を使用しないため安全:

| | Route C（実装） | 並列レビュー |
|--|----------------|-------------|
| sandbox | workspace-write | read-only |
| worktree | 使用（コンフリクトリスク） | 不使用 |
| ADR-004 制限 | 1並列 | 制限なし |

API レート制限を考慮し、同時実行は最大4プロセスを推奨。

### パフォーマンス

- `codex exec --sandbox read-only` は独立APIクエリとして動作
- 並列実行は Bash のバックグラウンドジョブ (`&` + `wait`) で実現
- 各プロセスは worktree を作らず、ファイル書き込みも行わない

### コスト

- Codex API 利用には OpenAI のクレジットが必要です
- レビュー頻度に応じたコスト見積もりを推奨

---

## 参考資料

- ADR-004: Codex大規模委任モデル (`docs/adr/004-codex-delegation-model.md`)
- delegation.md: Codex CLI 3経路 (`rules/delegation.md`)
- scripts/README.md: CLI routes (`scripts/README.md`)
- block-codex-mcp.sh: MCP ブロック hook (`hooks/block-codex-mcp.sh`)
