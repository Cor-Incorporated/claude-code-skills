---
name: handover
description: "Generate an agent-to-agent handover document (経路B) or next-session handoff from the current session state: repo, worktree, branch, open PRs/issues, scope, constraints, and the mandatory rule block. Invoke with: /handover [宛先: codex|cursor|opencode|次セッション]. Use when the user says 'ハンドオーバー作って', '引き継ぎ文書', '次のセッションへの引き継ぎ', 'Codexに渡す資料', 'handoff', or when context is running low and work must continue elsewhere. Do NOT use for: progress reports (use /wave-report), PR descriptions, or delegating a small single task (write the task prompt directly)."
---

# Handover — エージェント間引き継ぎ文書の生成

Claude → Codex / Cursor / OpenCode / 次セッションへの引き継ぎ文書を生成する。抜け漏れ（worktree パス、禁止事項、完了条件、委任契約）を防ぐ。

## 委任契約（必須 6 欄 — 埋まらない委任は発射しない）

1. 停止条件と最大反復: 既定 10（超えたら停止して報告）
2. 報告間隔 / 無進捗タイムアウト: 既定 30 分 / 2h（機械強制は harness H1）
3. 課金上限: $<実値を書く。既定 $10>
4. 発射前の実現可能性チェック: 「この委任が不可能であることを示す最安のクエリ」を
   先に実行し、コマンドと結果をここに貼る（貼付なしは欠陥）
5. 人間ゲート列挙（「リマインドのみ」セクションに分離）+ 待ち中の可否:
   準備=可 / 本番系の迂回経路新設=不可（迂回するなら停止・権限・巻き戻しの 1 枚合意を先に）
6. 反証可能な完了条件: 「何を実測すれば偽と分かるか」を 1 行で
7. [P7] 事前スパイク回答欄: 新規フレームワーク/外部 API は実ソース・実レジストリで
   確認したか。性能仮説は実測したか。org ポリシー（allowlist/quota）は確認したか。
   （「確認せず採用する」と明記して進むことは許可 — 空欄のみ不可）

欄名は受領側（Codex / Cursor / OpenCode AGENTS・rules）と一字一句一致させること。

## 手順

1. **現状を実データで収集**（すべて read-only）:
   ```bash
   git rev-parse --show-toplevel && git branch --show-current && git log --oneline -5
   git worktree list
   git status --porcelain | head -20
   gh pr list --state open --limit 10 --json number,title,headRefName,isDraft
   gh issue list --state open --limit 15 --json number,title,labels
   ```
2. **会話コンテキストから埋める**: 目的、経緯、未完了タスク、判断済み事項、ハマりポイント。
3. **委任契約 6+1 欄を必ず埋める**（上記）。空欄のまま発射しない。
4. **宛先別の調整**:
   - **Codex**: 絶対遵守ルールブロックを含める。
   - **Cursor / OpenCode**: 所有ファイル範囲と他 lane 非干渉を明記。
   - **次セッション**: TaskList 状態と最初に読むファイルを明記。
5. テンプレートで文書化し、保存先を確認: 標準は `docs/handover/YYYY-MM-DD-<topic>.md`。

## 文書テンプレート

```markdown
# Handover: <topic>
**作成日**: YYYY-MM-DD / **作成者**: Claude Code / **宛先**: <Codex|Cursor|OpenCode|次セッション>

## 作業環境
- Repo: <パス> / Branch: <name>
- Worktree: <パス>
- 現況: <clean / dirty>

## 目的（1〜2行）

## 経緯（3〜5行）

## 委任契約（必須）
1. 停止条件と最大反復: ...
2. 報告間隔 / 無進捗タイムアウト: ...
3. 課金上限: ...
4. 実現可能性チェック: <cmd + 結果>
5. 人間ゲート: ...
6. 完了条件（反証可能）: ...
7. 事前スパイク（レジストリ/実物照合）: ...

## タスク
1. <task> — 完了条件: <検証可能条件>

## 所有範囲
- 触ってよい: ...
- 禁止事項枠: ...

## 完了時の報告形式
- Evidence: <コマンド> | <要点 or ログパス> | <時刻>
- 回収コミット SHA / 削除 worktree・ブランチ / 判断待ち在庫

## 絶対遵守ルール（Codex宛のとき）
...
```

## 注意・禁止事項

- 認証情報を文書に含めない。
- 完了条件のないタスクを書かない。
- one-shot 委任（検収往復なし）は禁止（delegation.md）。
