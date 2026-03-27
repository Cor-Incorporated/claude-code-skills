---
name: classify-review
description: "PR review severity を Haiku AI で再分類。regex 偽陽性を除外する片方向ゲート。/classify-review [PR番号] で実行。regex が CRITICAL/HIGH 検出した際の偽陽性チェック専用。"
user-invocable: true
argument-hint: "[PR番号]"
allowed-tools: [Read, Write, Bash, Grep, Agent]
---

# /classify-review — AI Severity Re-classification (False Positive Filter)

regex ベースの severity 検出が CRITICAL/HIGH を報告した際に、Haiku AI で偽陽性かどうかを判定する。

## 設計原則: 片方向ゲート (fail-closed)

- AI は severity を**下げる方向にのみ**動ける（偽陽性の除外）
- AI が severity を**上げることはない**
- 不確実な場合は**ブロック維持**（安全側に倒す）
- 全判定は reasoning 付きでログ

## 実行手順

### Step 1: State File 読み取り

`.claude/state/pending-review-comments.json` を Read する。
なければ `~/.claude/state/pending-review-comments.json` を試す。

必須フィールド: `pr`, `critical`, `high`, `raw_comments`, `head_sha`

### Step 2: 分類が必要か判定

- `critical == 0` AND `high == 0` の場合 → 「偽陽性なし。分類不要。」と報告して終了
- `raw_comments` が空の場合 → 「コメントデータなし。分類不要。」と報告して終了

### Step 3: Haiku サブエージェントで偽陽性判定

regex が CRITICAL/HIGH を検出したコメントのみを Haiku に提示する。
以下のように Agent tool を使用:

```
Agent(
  model="haiku",
  subagent_type="general-purpose",
  prompt="""
あなたはコードレビューコメントの severity 分類器です。
以下のコメントが REGEX パターンマッチで CRITICAL または HIGH として検出されました。
各コメントについて、これが「本物のコード品質/セキュリティ指摘」か「偽陽性」かを判定してください。

## 判定基準

「本物の指摘」(real):
- コードの実際のバグ、脆弱性、データ損失リスクを報告している
- 具体的なファイル名・行番号・問題の説明がある
- [CRITICAL], **HIGH**, severity: CRITICAL 等の構造化マーカー付きの指摘

「偽陽性」(false_positive):
- 否定文脈: "No CRITICAL issues", "CRITICAL=0", "0 HIGH findings"
- メタ言及: "CRITICALの検出パターンを追加", "severity検出ロジック"
- ボットテンプレート/メタデータ: CodeRabbit の HTML テンプレート
- 承認メッセージ: "LGTM", "Approved for merge"
- サマリー: "No actionable comments were generated"

不明な場合は必ず「本物の指摘」(real) として扱ってください。

## コメント一覧
{raw_comments の内容をここに展開}

## 出力形式
各コメントに対して以下の JSON を返してください:
[
  { "index": 0, "user": "...", "verdict": "real" | "false_positive", "reasoning": "判定理由を1文で" },
  ...
]
"""
)
```

### Step 4: 判定結果で State File 更新

Haiku の判定結果に基づいて `pending-review-comments.json` を Write で更新:

1. `classification_method` を `"ai"` に変更
2. 偽陽性と判定されたコメントの severity カウントを除外して再計算
3. 「本物」「不明」のコメントの severity はそのまま維持
4. `ai_classification` ブロックに詳細を格納:

```json
{
  "ai_classification": {
    "critical": 0,
    "high": 0,
    "classified_at": "2026-03-27T...",
    "classified_by": "haiku",
    "verdicts": [
      { "index": 0, "user": "terisuke", "verdict": "false_positive", "reasoning": "承認メッセージ。否定文脈で CRITICAL/HIGH を言及しているだけ" }
    ]
  }
}
```

5. トップレベルの `critical`/`high` も AI 判定結果で更新（下流 consumer との互換性維持）

### Step 5: 結果報告

分類結果のサマリーを出力:

```
## /classify-review 結果 (PR #XX)

| # | User | Regex判定 | AI判定 | 理由 |
|---|------|----------|--------|------|
| 1 | @terisuke | CRITICAL | false_positive | 承認メッセージ内の否定文脈 |

Regex: CRITICAL=1 HIGH=1 → AI: CRITICAL=0 HIGH=0
State file 更新済み。マージゲートは解除されます。
```

## 安全性保証

- Haiku が 1 つでも `"real"` と判定 → その severity はカウント維持 → ブロック維持
- Haiku が判定不能/エラー → 全て `"real"` 扱い → ブロック維持
- `head_sha` が変わったら AI 分類は無効（push 後は再分類必要）
- 全判定に `reasoning` ログ → 事後監査可能
