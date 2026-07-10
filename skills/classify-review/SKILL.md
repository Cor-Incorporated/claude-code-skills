---
name: classify-review
description: "PR review severity を Haiku AI で再分類。regex 偽陽性を除外する片方向ゲート。/classify-review [PR番号] で実行。regex が CRITICAL/HIGH 検出した際の偽陽性チェック専用。"
user-invocable: true
argument-hint: "[PR番号]"
allowed-tools: [Read, Bash, Grep, Agent]
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

必須フィールド: `pr`, `repo`, `critical`, `high`, `raw_comments`, `head_sha`, `comment_set_hash`

`raw_comments[]` は `index`, `comment_hash`, `critical`, `high`, `body_preview` を確認できる形で Haiku に渡す。

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
  {
    "index": 0,
    "comment_hash": "...",
    "verdict": "real" | "false_positive" | "unknown",
    "reasoning": "判定理由を1文で"
  },
  ...
]
"""
)
```

### Step 4: 判定結果を正規 updater に渡す

`pending-review-comments.json` を Write/Edit で直接更新してはいけない。
Haiku の JSON を1つの shell argument として `classify-review-state.sh` に渡す:

```bash
VERDICTS_JSON='[{"index":0,"comment_hash":"...","verdict":"false_positive","reasoning":"承認メッセージであり、実指摘ではない"}]'
bash ~/.claude/scripts/classify-review-state.sh <PR番号> "$VERDICTS_JSON" <OWNER/REPO>
```

updater は以下を検証してから atomic + flock で state file を更新する:

1. `classification_method` を `"ai"` に変更
2. PR番号、repo、`head_sha` が現在のGitHub PRと一致することを確認
3. GitHub から現在のレビューコメント集合を再取得し、`comment_set_hash` が一致することを確認
4. `comment_hash` が `raw_comments[index]` と一致することを確認
5. 偽陽性判定かつコメント本文が承認/否定文脈として deterministic に安全な場合だけ severity カウントから除外
6. 「本物」「不明」、または deterministic severity-negation pattern に合わないコメントの severity はそのまま維持
7. `ai_classification` ブロックに詳細を格納:

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

8. トップレベルの `critical`/`high` も AI 判定結果で更新（下流 consumer との互換性維持）

exit code:

- `0`: 分類保存済み。CRITICAL/HIGH は 0。
- `1`: 入力不正、stale head、hash mismatch、missing verdict 等。state file は未変更。
- `2`: 分類保存済み。ただし real/unknown の CRITICAL/HIGH が残るためブロック維持。

### Step 5: 結果報告

分類結果のサマリーを出力:

```
## /classify-review 結果 (PR #XX)

| # | User | Regex判定 | AI判定 | 理由 |
|---|------|----------|--------|------|
| 1 | @terisuke | CRITICAL | false_positive | 承認メッセージ内の否定文脈 |

Regex: CRITICAL=1 HIGH=1 → AI: CRITICAL=0 HIGH=0
classify-review-state.sh による検証済み更新完了。state file (`pending-review-comments.json`) は更新済み。
※ この severity 集計を読んでマージをブロックする hook（旧 pr-ci-review-gate.sh / block-merge-without-review.sh）は
  hook削減により `hooks/_unused/` へ退避済みで現在は発火しない。マージ可否は現状レビュー内容を見て判断すること。
```

## 安全性保証

- Haiku が 1 つでも `"real"` と判定 → その severity はカウント維持 → ブロック維持
- Haiku が判定不能/エラー → 全て `"real"` 扱い → ブロック維持
- `head_sha` が変わったら AI 分類は無効（push 後は再分類必要）
- `comment_set_hash` が変わったら AI 分類は無効（同一headへのレビュー追加/編集後は再分類必要）
- `comment_hash` が一致しない判定は無効（state file 未変更）
- `false_positive` 判定でも、コメント本文自体が承認/否定文脈でない場合は severity を下げない
- AI/Agent は `pending-review-comments.json` を直接 Write しない
- 全判定に `reasoning` ログ → 事後監査可能
