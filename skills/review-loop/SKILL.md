---
name: review-loop
description: CI green + claude-review LGTM まで自動ループ。push → CI待ち → 全レビューソースチェック → 修正 → 再push を繰り返す
user-invocable: true
argument-hint: "[PR番号] [--all-prs]"
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob]
---

# /review-loop — CI + Review 自動修正ループ

PR の CI/CD が全てグリーンになり、かつ claude-review の指摘が全て解消されるまで自動的にループする。

## 使い方
```
/review-loop 218          # 単一PR
/review-loop --all-prs    # 全open PRをチェック
```

## ループの流れ

```
┌─────────────────────────────────────────────┐
│ 1. CI/CD チェック (gh pr checks)             │
│    ├─ FAIL → build-error-resolver で修正     │
│    └─ PASS → 次へ                           │
├─────────────────────────────────────────────┤
│ 2. レビュー全ソースチェック                    │
│    ├─ Source 1: /pulls/{pr}/reviews (body)   │
│    ├─ Source 2: /pulls/{pr}/comments (inline)│
│    └─ Source 3: /issues/{pr}/comments (summary)│
├─────────────────────────────────────────────┤
│ 3. 指摘分類                                  │
│    ├─ MUST FIX → エージェントで並列修正       │
│    ├─ SHOULD FIX → エージェントで修正         │
│    └─ OBSERVATION → コメントのみ、修正不要     │
├─────────────────────────────────────────────┤
│ 4. 修正 commit & push                       │
│    └─ ステップ1に戻る                        │
├─────────────────────────────────────────────┤
│ 5. ALL GREEN + NO MUST/SHOULD FIX           │
│    → ✅ LGTM宣言、merge可能                  │
└─────────────────────────────────────────────┘
```

## 実行手順

<important if="running CI checks or diagnosing CI failures on a PR">

### Step 1: CI/CDステータス確認
```bash
gh pr checks {PR_NUMBER}
```
- 全て `pass` → Step 2 へ
- `fail` あり → 失敗ログを取得し、build-error-resolver エージェントで修正
- `pending` → 待機（最大10分）

</important>

<important if="collecting review comments from GitHub PR or checking review coverage">

### Step 2: 全レビューソースチェック（3箇所必須）
```bash
bash ~/.claude/scripts/check-pr-reviews.sh {PR_NUMBER}
```

このスクリプトは以下の3箇所全てを確認する:
1. `gh api repos/{owner}/{repo}/pulls/{pr}/reviews` — レビューbody
2. `gh api repos/{owner}/{repo}/pulls/{pr}/comments` — インラインコメント
3. `gh api repos/{owner}/{repo}/issues/{pr}/comments` — レビューサマリ（issue comments）

**重要**: `/issues/{pr}/comments` のレビューサマリを見落とさないこと！
claude-review は以下の3つの方法でコメントを残す:
- レビューbody（空のことが多い）
- インラインコメント（特定行への指摘）
- issue comment（全体サマリ、MUST FIX / SHOULD FIX の分類あり）

### Step 3: 最新レビューの指摘内容を取得
```bash
# 最新のレビューサマリ（最重要）
gh api "repos/{owner}/{repo}/issues/{pr}/comments" \
  --jq '[.[] | select(.user.login == "claude[bot]")] | last | .body'

# 最新pushのインラインコメント
gh api "repos/{owner}/{repo}/pulls/{pr}/comments" \
  --jq '[.[] | select(.user.login == "claude[bot]")] | last(5) | {path, line, body}'
```

</important>

<important if="processing review feedback and classifying review findings for a PR">

### Step 4: 指摘を分類して修正
- **MUST FIX / 🔴 / Bug**: 必ず修正。エージェントに委任可能
- **SHOULD FIX / 🟠**: 修正推奨。エージェントに委任可能
- **OBSERVATION / 🟡 / Minor / Nit**: 修正不要。次のPRで対応可

### Step 5: 修正 → commit → push → ループ
```bash
# 修正をコミット
git add -A && git commit -m "fix: address claude-review round N findings"
git push origin {branch}
```
→ Step 1 に戻る

</important>

<important if="determining whether a PR is ready to merge or declaring LGTM">

### Step 6: LGTM判定
以下の条件を全て満たした場合にLGTM:
- [ ] `gh pr checks` が全て pass
- [ ] 最新レビューサマリに MUST FIX が 0
- [ ] 最新インラインコメントに未対応の指摘が 0
- [ ] ruff format / gofmt / eslint がクリーン

</important>

## ルール
- **最大ループ回数**: 5回。5回で収束しない場合はユーザーに報告
- **エージェント活用**: 修正は必ずバックグラウンドエージェントに委任（コンパクティング回避）
- **並列修正**: 複数PRの修正は並列エージェントで実行
- **ruff/gofmt**: 修正commitの前に必ずフォーマッタを実行
- **レビュータイムスタンプ検証**: pushごとに最新レビューが最新pushより後であることを確認
