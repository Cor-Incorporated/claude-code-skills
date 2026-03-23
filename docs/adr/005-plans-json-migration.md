# ADR-005: Plans.md → JSON 形式移行の検討

## ステータス
Rejected

## 日付
2026-03-23

## コンテキスト

[ベストプラクティス記事](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/)は
「MarkdownよりJSONが適。モデルがJSON形式データを不適切に編集・上書きする可能性はMarkdownより低い」
と推奨している。

現在の Plans.md は claude-code-harness プラグインが管理しており、
タスクの追加・更新・マーカー操作を Markdown 形式で行っている。

## 検討した代替案

### 案A: 完全JSON移行
- Plans.md → plans.json
- 全スキルをJSON対応に書き換え

### 案B: ハイブリッド（JSON + Markdownサマリ）
- plans.json をSSOT、Plans.md は読み取り専用ビュー
- hookで自動同期

### 案C: 現状維持（Markdown）
- 変更なし

## 決定

**案C: 現状維持（Markdown）を選択。**

## 理由

1. **プラグイン依存度**: claude-code-harness の plans-management, sync-status, session 等の
   スキルが Plans.md の Markdown 構造に深く依存。JSON移行は大規模リファクタが必要。

2. **人間の可読性**: Plans.md は開発者がエディタで直接読み書きする。
   JSONは人間の編集に不向き（括弧・カンマの構文エラーリスク）。

3. **記事の注記**: ベストプラクティス記事自身が「短期的なタスク管理向け」と
   位置づけており、長期プロジェクト計画には Markdown の方が適切。

4. **コスト対効果**: 10+スキルの書き換え + テスト + 互換性維持のコストが、
   「上書きリスク軽減」の利益を上回る。

5. **実績**: 現行の Markdown 方式で重大な上書き事故は発生していない。

## 結果

- Plans.md は Markdown 形式を維持する
- 将来的に上書き事故が頻発する場合は本ADRを Superseded にして再検討する
- hookによる Plans.md 保護（不正な全削除の防止等）は別途検討可能
