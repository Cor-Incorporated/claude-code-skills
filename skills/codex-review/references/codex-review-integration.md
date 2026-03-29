---
name: codex-review-integration
description: "Codex CLI を使用したレビュー実行手順"
allowed-tools: ["Read", "Bash"]
---

# Codex レビュー実行（CLI版）

Codex CLI (`codex exec`) を使用してコードレビューを実行する手順。

> **重要**: Codex MCP (`mcp__codex__*`) は使用禁止です（`block-codex-mcp.sh`）。
> 全ての呼び出しは `codex exec` CLI 経由で行います。
> Ref: delegation.md, ADR-004, Issue #72, Issue #197

---

## 概要

Codex CLI が設定済みの場合、以下の方法でレビューを実行できます:

1. **`/harness-review` 経由**: 自動的に Codex CLI 統合
2. **直接 CLI 呼び出し**: `codex exec` を直接使用
3. **経路A**: `codex-parallel.sh --review` を使用

---

## 実行方法

### 方法1: /harness-review 経由（推奨）

```
ユーザー: /harness-review
    ↓
harness-review スキル起動
    ↓
codex.enabled 確認 → true
    ↓
Claude + Codex CLI 並列レビュー
    ↓
結果統合
```

### 方法2: codex-parallel.sh 経由（経路A）

```bash
# レビューモードで実行
bash ~/.claude/scripts/codex-parallel.sh --review "$(pwd)" --base develop
```

### 方法3: codex exec 直接呼び出し

```bash
# 単発レビュー
codex exec --sandbox read-only \
  "以下のコードをレビューしてください: $(git diff --name-only HEAD~1)"

# 出力ファイル指定
codex exec --sandbox read-only \
  -o /tmp/codex-review-result.md \
  "以下の変更をレビューしてください: $(git diff HEAD~1)"
```

---

## レビュープロンプト

### デフォルトプロンプト

```
日本語でコードレビューを行い、問題点と改善提案を出力してください
```

### カスタマイズ例

**セキュリティ重視**:
```yaml
review:
  codex:
    prompt: |
      以下の観点でセキュリティレビューを行ってください:
      1. 入力検証の不備
      2. 認証・認可の問題
      3. インジェクション脆弱性
      4. 機密情報の露出
```

**パフォーマンス重視**:
```yaml
review:
  codex:
    prompt: |
      以下の観点でパフォーマンスレビューを行ってください:
      1. N+1クエリ
      2. 不要な再レンダリング
      3. メモリリーク
      4. 非効率なアルゴリズム
```

---

## レビュー結果の形式

### 統合フォーマット

```markdown
## Codex レビュー結果

**サマリ**: 3件の改善提案

### 問題点

| ファイル | 行 | 重要度 | 内容 |
|---------|-----|--------|------|
| src/api/users.ts | 45 | 高 | SQL インジェクションの可能性 |
| src/components/Form.tsx | 12 | 中 | useEffect の依存配列が不完全 |

### 改善提案

1. 関数を分割して可読性を向上
2. 型定義を厳密化
```

---

## エラーハンドリング

### タイムアウト

```bash
# タイムアウト付きで実行（120秒）
timeout 120 codex exec --sandbox read-only "..." || echo "Codex review timed out"
```

### API エラー

Codex CLI がエラーを返した場合:
1. `codex login status` で認証確認
2. OpenAI ダッシュボードでクレジット確認
3. レート制限の場合は時間を置いて再試行

---

## ベストプラクティス

### 効果的なレビューのために

1. **対象を絞る**: 重要なファイルに集中
2. **観点を明確に**: プロンプトでレビュー観点を指定
3. **結果を比較**: Claude と Codex の指摘を比較して優先度判断

### MCP ではなく CLI を使う理由

| 観点 | MCP (廃止) | CLI (推奨) |
|------|-----------|------------|
| sandbox | なし | read-only/workspace-write |
| worktree | 非対応 | 対応 |
| hook 互換 | block-codex-mcp.sh でブロック | 正常動作 |
| 進捗表示 | なし | あり |

### 並列実行の安全性

ADR-004 の「Max 1 concurrent Codex request」は Route C（実装・workspace-write）に対するルール。
`codex exec --sandbox read-only` によるレビューは worktree を使用せず、ファイル書き込みも行わないため
並列実行しても安全。API レート制限を考慮し同時最大4プロセスを推奨。

---

## 関連ドキュメント

- `scripts/codex-parallel.sh` — 経路A/C CLI スクリプト
- `hooks/block-codex-mcp.sh` — MCP ブロック hook
- `docs/adr/004-codex-delegation-model.md` — Codex 委任モデル
- `rules/delegation.md` — 委任ルール
