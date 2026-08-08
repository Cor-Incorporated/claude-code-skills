---
name: plan
description: "Create a phased implementation plan before writing any code: restate requirements, identify risks and dependencies, estimate complexity, then WAIT for explicit user approval (hard gate). After approval, optionally convert the plan into a checklist document under docs/plans/. Invoke with: /plan [feature description]. Use when: starting a new feature, significant architectural changes, complex refactoring, multi-file work, or ambiguous requirements. Do NOT use for: trivial single-file fixes, design exploration before requirements exist (use /brainstorming), or bug fixing (use /bugfix)."
user-invocable: true
argument-hint: "[feature or change description]"
allowed-tools: [Read, Grep, Glob, WebSearch, Write, AskUserQuestion]
---

# Plan（実装計画 + 承認ゲート + チェックリスト化）

コードに触れる前に段階的な実装計画を作成し、**ユーザーの明示承認を待つ**。planner エージェントを活用してよい。

## /brainstorming との使い分け

- 要件そのものが固まっていない・設計案を比較したい → `/brainstorming`
- 作るものは決まっていて、実装手順とリスクを固めたい → `/plan`（本スキル）
- 典型フロー: `/brainstorming` → `/plan` → 実装

## 着手前必須欄（欄の空欄は不可。「該当なし」は可）

対象: 新規機能・委任・0.5 日以上のタスク。

1. 一次資料パス: <原指示・references・定義ファイルの絶対パスを列挙>
2. 要求インベントリ: 一次資料から 1 行 1 項目で機械列挙（記憶からの起草禁止）
3. 突合表: インベントリ ↔ 受入基準の 1:1 対応表
4. 標準質問 5 問: ユーザー像 / 審美 / LLM 挙動境界 / 安全境界 / セキュリティ境界
5. [LLM を製品出力に組み込む場合のみ] 決定境界表:
   | LLM が決める事項 | 決めない事項 | 決めない事項の決定的経路 |

改訂が 2 回を超えたら継ぎ足し禁止・全面リライト。初日に実物 1 本を人間に見せる。

## ワークフロー

### 1. 要件の再確認
- 依頼内容を明確な言葉で再記述する。
- 必須欄 1〜5 を埋めてからフェーズ分解に入る。
- 曖昧な点は AskUserQuestion で確認する。

### 2. フェーズ分解
- 実装を具体的で実行可能なステップに分割する。
- 各フェーズに対象ファイル/コンポーネントを明記する。

### 3. 依存関係とリスク評価
- 依存関係を列挙し、リスクを HIGH / MEDIUM / LOW で評価する。

### 4. 複雑度見積もり
- 全体の複雑度とフェーズ別の目安時間を提示する（見積もりは「（未検証）」と明記）。

### 5. 承認ゲート（ハードゲート — 厳守）
- 計画を提示し、末尾に必ず `**WAITING FOR CONFIRMATION**: このプランで進めますか？ (yes/no/modify)` を付ける。
- **ユーザーが明示承認するまで、コードの Edit/Write/変更系 Bash を一切実行しない。**

### 6. チェックリスト化（承認後・任意）
1. 承認された計画を Markdown チェックリストに変換する。
2. `docs/plans/YYYY-MM-DD-<topic>.md` に保存する。

## 出力形式

```markdown
# Implementation Plan: [タイトル]

## 着手前必須欄
- 一次資料パス: ...
- 要求インベントリ: ...
- 突合表: ...
- 標準質問: ...
- 決定境界表: ...（該当時）

## Requirements Restatement
- ...

## Implementation Phases
### Phase 1: ...

## Dependencies
## Risks
## Estimated Complexity

**WAITING FOR CONFIRMATION**: このプランで進めますか？ (yes/no/modify)
```

## 注意

- **承認前にコードを書き始めることは絶対禁止。**
- 改訂カウンタを自分で数え、3 回目で全面リライトを提案する。
- 計画時点の見積もりは「（未検証）」の推定であることを明記する。
