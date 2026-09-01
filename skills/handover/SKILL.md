---
name: handover
description: "Generate an agent-to-agent handover document (経路B) or next-session handoff from the current session state: repo, worktree, branch, open PRs/issues, scope, constraints, and the mandatory rule block. Invoke with: /handover [宛先: codex|cursor|opencode|次セッション]. Use when the user says 'ハンドオーバー作って', '引き継ぎ文書', '次のセッションへの引き継ぎ', 'Codexに渡す資料', 'handoff', or when context is running low and work must continue elsewhere. Do NOT use for: progress reports (use /wave-report), PR descriptions, or delegating a small single task (write the task prompt directly)."
---

# Handover — エージェント間引き継ぎ文書の生成

Claude → Codex / Cursor / OpenCode / 次セッションへの引き継ぎ文書を生成する。抜け漏れ（worktree パス、禁止事項、完了条件、委任契約）を防ぐ。

## 委任契約（必須欄 — 埋まらない委任は発射しない）

1. 停止条件と最大反復: 既定 10（超えたら停止して報告）
2. 報告間隔 / 無進捗タイムアウト: 既定 30 分 / 45 分（機械強制は harness H1）
3. 課金上限: $<実値を書く。既定 $5>
4. 発射前の実現可能性チェック: 「この委任が不可能であることを示す最安のクエリ」を
   先に実行し、コマンドと結果をここに貼る（貼付なしは欠陥）。
   **到達の前提条件を含める**: 委任が依存する強制点・設定・workflow が
   **対象リポ・対象 locus に実在するか**を `gh api` / `ls` で実測して貼る。
   「配備されているはず」は欠陥。〔2026-08-22 追加。Phase 11/20/21 で監督が
   テンプレ・payload・h5 の配備を確認せずに設計し、到達 0% / 3-4 欄 / 1/4 を招いた〕
5. 人間ゲート列挙（「リマインドのみ」セクションに分離）+ 待ち中の可否:
   準備=可 / 本番系の迂回経路新設=不可（迂回するなら停止・権限・巻き戻しの 1 枚合意を先に）
6. 反証可能な完了条件: 「何を実測すれば偽と分かるか」を 1 行で
7. [P7] 事前スパイク回答欄: 新規フレームワーク/外部 API は実ソース・実レジストリで
   確認したか。性能仮説は実測したか。org ポリシー（allowlist/quota）は確認したか。
   （「確認せず採用する」と明記して進むことは許可 — 空欄のみ不可）
8. 完了条件の検査: 着手前に、各完了条件について「満たしても目的未達の入力」を
   1 つ構成できるか試み、できたら着手前に差し戻す（着手後の追記は無効）
9. 追加を提案しない: **新しい**ガード・hook・workflow・required check が必要と判断したら
   **実装せず提案して停止**する（Issue #27 凍結）。
   **ただし「装置の追加」と「既存装置の被覆修復」を区別する。**
   既存の強制点が塞ぐべき形を塞げていないと分かった場合、それは**追加ではなく修復**であり、
   **その場で塞ぐことが required**。発見だけして「スコープ外」「追加しなかったもの」に
   計上して閉じてはならない（無効化条項の禁止 = completion-criteria-spec.md §2-1）。
   判定: **新しいファイル・新しい登録・新しい required check が要る → 追加（禁止）。
   既存ファイルの判定条件を直すだけ → 修復（必須）。**
   修復した場合は F1（入力空間の列挙）で修正前 red を実測して示すこと。
   〔2026-08-11 追加。本欄が無かった 2 波で、Codex の `+HEAD:main` と
   Claude Code の `refs/heads/` 系の穴が、発見済みのまま連続して放置された〕
10. 強制点の実測表: **2 ツール以上に触れる委任**は、設計節より前に次の表を埋める。
    空欄が 1 つでもあれば着手前に差し戻す。
    | ツール | 強制点のパス | 入力契約 | 同一マトリクスでの実測 | 測定コマンド |
    |---|---|---|---|---|
    （測定器: `claude-code-skills/tests/test-cross-tool-force-matrix.sh`）

欄名は受領側（Codex / Cursor / OpenCode AGENTS・rules）と一字一句一致させること。

## H8 発射前補助欄（必須）

委任契約の既存 10 欄は変更せず、以下の 7 欄を別節として持たせる。
各欄の本文は 20 文字以上。これは宣言形式の強制であり、内容の真実性や
実装前に書かれたことまでは機械判定できない。

1. 一次資料: 要求を抽出した Issue・ADR・仕様のパスまたは URL
2. 要求インベントリ: 実装と照合する要求の全件一覧
3. 突合表: 要求と受入基準・証跡の対応表
4. 標準質問: ユーザー像・審美・LLM 挙動境界・安全境界・セキュリティ境界
5. 北極星: メトリクスと測定周期
6. 反証軸: F1 の軸・真理値、F2 の事故入力・再現入力、F3 の片側変異のいずれかを実装前に記載
7. 撤収: 回収先と `active / recover / preserve / retire` のいずれか

`テスト green`のみは反証軸として扱わない。

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
3. **委任契約の必須欄を必ず埋める**（上記）。空欄のまま発射しない。
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
8. 完了条件の検査: ...
9. 追加を提案しない: ...
10. 強制点の実測表: <横断時のみ。空欄なら差し戻し>

## 一次資料
<Issue・ADR・仕様のパスまたは URL と、どの要求の出典か>

## 要求インベントリ
<実装と照合する要求を漏れなく列挙する>

## 突合表
<各要求と受入基準・実測証跡の対応を表示する>

## 標準質問
<ユーザー像・審美・LLM 挙動境界・安全境界・セキュリティ境界への回答>

## 北極星
<目的到達を測るメトリクスと測定周期、判定に使う数値の出典>

## 反証軸
<F1 の軸・F2 の事故入力・F3 の片側変異のいずれかを 20 文字以上で記載>

## 撤収
<回収先と active / recover / preserve / retire のいずれかを記載>

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
