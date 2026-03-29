# Codex レビュー実行（CLI版）

`codex exec --sandbox read-only` を使用したレビュー実行手順。

> **重要**: Codex MCP (`mcp__codex__*`) は使用禁止（`block-codex-mcp.sh`）。
> Ref: delegation.md, ADR-004, Issue #72, Issue #197

---

## 実行方法

全てのレビューは `codex exec --sandbox read-only` で統一。

### 単発レビュー

```bash
# 基本形
codex exec -C "$(pwd)" --sandbox read-only \
  "以下の変更をレビューしてください: $(git diff HEAD~1)"

# 出力をファイルに保存（stdout キャプチャ推奨）
codex exec -C "$(pwd)" --sandbox read-only \
  "以下の変更をレビューしてください: $(git diff HEAD~1)" | tee /tmp/review.md
```

> **Note**: `-o` (`--output-last-message`) はエージェントの最後のメッセージのみ出力。
> 完全な出力には `| tee` または `> file.md` を使用。

### 並列エキスパートレビュー

複数のエキスパートプロンプトを並列実行:

```bash
codex exec -C "$(pwd)" --sandbox read-only \
  "$(cat experts/security-expert.md)" > /tmp/review-security.md 2>/dev/null &
codex exec -C "$(pwd)" --sandbox read-only \
  "$(cat experts/quality-expert.md)" > /tmp/review-quality.md 2>/dev/null &
wait
```

**詳細**: [codex-parallel-review.md](./codex-parallel-review.md)

### /harness-review 経由

```
/harness-review → codex.enabled=true → codex exec 自動実行 → 結果統合
```

---

## レビュープロンプト例

**セキュリティ重視**:
```
以下の観点でセキュリティレビューを行ってください:
1. 入力検証の不備
2. 認証・認可の問題
3. インジェクション脆弱性
4. 機密情報の露出
```

**パフォーマンス重視**:
```
以下の観点でパフォーマンスレビューを行ってください:
1. N+1クエリ
2. 不要な再レンダリング
3. メモリリーク
4. 非効率なアルゴリズム
```

---

## エラーハンドリング

### タイムアウト

macOS では `gtimeout`（coreutils）を使用:

```bash
gtimeout 120 codex exec --sandbox read-only "..." || echo "Codex review timed out"
```

### API エラー

1. `codex login status` で認証確認
2. OpenAI ダッシュボードでクレジット確認
3. レート制限時は時間を置いて再試行

---

## CLI を使う理由（MCP 廃止）

| 観点 | MCP (廃止) | CLI (推奨) |
|------|-----------|------------|
| sandbox | なし | read-only/workspace-write |
| worktree | 非対応 | 対応 |
| hook 互換 | block-codex-mcp.sh でブロック | 正常動作 |
| 並列安全性 | N/A | read-only で並列安全 |

---

## 関連ドキュメント

- [codex-parallel-review.md](./codex-parallel-review.md) — 並列実行ガイド
- `hooks/block-codex-mcp.sh` — MCP ブロック hook
- `docs/adr/004-codex-delegation-model.md` — Codex 委任モデル
