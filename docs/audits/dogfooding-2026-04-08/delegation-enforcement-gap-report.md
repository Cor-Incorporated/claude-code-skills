# 委任ルール強制の構造的欠陥レポート

**日付**: 2026-04-08
**対象**: Issue #420 計画フェーズで4回差し戻しが発生した原因調査
**調査者**: Claude Code (Opus 4.6)

---

## エグゼクティブサマリー

Issue #420 の実装計画が **4回ユーザーに差し戻された**。原因は Codex CLI、Agent Team、Sub Agent の適切な振り分けが計画に含まれていなかったため。調査の結果、**委任ルールがプランモード中に一切強制されていない**ことが判明した。

---

## 差し戻しの経緯

| 回数 | ユーザーの指摘 | 欠けていた要素 |
|------|-------------|-------------|
| 1回目 | 「CLIテストだけでは前回と同じ」 | 本番環境での証明方法が未記載 |
| 2回目 | 「クローズしたイシューの検証が不十分」 | Issue #363 (構造的テスト問題) が計画に未反映 |
| 3回目 | 「コンテキスト制限に引っかかる」 | 全タスクが Claude Code 直接実装 → Agent Team 未使用 |
| 4回目 | 「Codex CLI を使わないのか」 | Codex CLI 経路C/A 未使用、ダブルレビュー未記載 |

---

## 根本原因: 3つの構造的欠陥

### 欠陥 1: プラン承認時のフック不在

```
settings.json の hook イベント一覧:
✅ SessionStart
✅ PreToolUse / PostToolUse
✅ TaskCompleted
✅ Stop / PreCompact
❌ PrePlanApproval  ← 存在しない
❌ ExitPlanMode     ← フックイベントなし
❌ TaskCreate       ← フックイベントなし
```

**影響**: プラン承認は UI フロー（ExitPlanMode ツール呼び出し）だが、このツールに対するフックが登録されていない。どんな委任構成のプランでもノーチェックで承認される。

### 欠陥 2: プランモードで委任チェックが免除される

`~/.claude/hooks/context-budget-agent-gate.sh` (line 52-61):

```bash
if [[ "$MODE" == "planning" ]] || [[ "$MODE" == "research" ]]; then
  exit 0  # ← 全ての委任チェックをスキップ
fi
```

**影響**: プランモード中は以下のルールが全て無効化:
- エージェント並列上限 (5-7)
- Codex CLI 上限 (1)
- TeamCreate 推奨 (2+独立タスク時)

### 欠陥 3: アドバイザリーフックがブロックしない

| フック | 検出時の動作 | 期待される動作 |
|--------|-----------|-------------|
| `enforce-codex-for-impl.sh` | `exit 0` (警告のみ) | `exit 2` (ブロック) |
| `enforce-codex-delegation.sh` | `exit 0` (警告のみ) | `exit 2` (ブロック) |
| `context-budget-agent-gate.sh` | 3+で警告、5+でブロック | 計画段階で構成を検証 |

---

## ルール vs 実際の強制状況マトリクス

| delegation.md のルール | 強制フック | ブロック? | プランモードで有効? |
|----------------------|----------|---------|-----------------|
| 2+独立タスク → TeamCreate | `context-budget-agent-gate.sh` | ⚠️ 警告のみ | ❌ 免除 |
| 長大タスク → Codex CLI 経路C | `enforce-codex-for-impl.sh` | ⚠️ 警告のみ | ❌ 免除 |
| レビュー → code-reviewer + Codex A | `pr-ci-review-gate.sh` | ✅ ブロック | PR操作時のみ |
| Codex CLI 上限 = 1 | `codex-task-gate.sh` | ✅ ブロック | 実行後のみ (計画段階では無効) |
| 並列上限 ≤ 7 | `context-budget-agent-gate.sh` | ⚠️ 5+でブロック | ❌ 免除 |

---

## 推奨修正 (優先順位順)

### P0: ExitPlanMode フックの追加

**提案**: `ExitPlanMode` ツールに `PreToolUse` フックを登録し、計画ファイル内の委任構成を検証する。

```bash
# enforce-plan-delegation.sh (新規)
# 計画ファイルを読み込み、以下を検証:
# 1. 2+独立タスクが存在する場合、Agent Team または worktree 並列が記載されているか
# 2. 3+ファイル跨ぎのリファクタが Codex CLI に委任されているか
# 3. レビューパイプライン（code-reviewer + Codex 経路A）が含まれているか
# 4. 「直った証明」セクションが存在するか
```

settings.json への登録:
```json
{
  "event": "PreToolUse",
  "hooks": [{
    "matcher": "ExitPlanMode",
    "command": "bash ~/.claude/hooks/enforce-plan-delegation.sh"
  }]
}
```

### P1: プランモード免除の条件付き解除

`context-budget-agent-gate.sh` のプランモード免除を **読み取り操作のみ** に限定:

```bash
# 変更前:
if [[ "$MODE" == "planning" ]]; then exit 0; fi

# 変更後:
if [[ "$MODE" == "planning" ]] && [[ "$TOOL" != "ExitPlanMode" ]]; then exit 0; fi
```

### P2: アドバイザリーフックのハードブロック化

`enforce-codex-for-impl.sh` と `enforce-codex-delegation.sh` を `exit 0` → `exit 2` に変更。

### P3: 計画テンプレートへの必須セクション追加

計画ファイルに以下のセクションを必須化:
- `## タスク委任マトリクス` — 各タスクの委任先を明記
- `## レビューパイプライン` — ダブルレビュー手順
- `## 証明方法` — 各バグの「直った証明」

---

## 追加調査: 実装フェーズの構造的欠陥 (2026-04-08 追記)

計画承認後の実装フェーズでも以下の構造的問題が発覚した。

### 欠陥 4: PR コンフリクト検出の不在

**事象**: PR #421 が `develop` ブランチとコンフリクト状態 (`mergeStateStatus: DIRTY`) にも関わらず、Claude Code はこれを検出せず作業を継続した。

**原因**:
- `gh pr create` 後に `gh pr view --json mergeable` を確認するフックがない
- ブランチ `fix/420-vertex-ai-migration-complete` は `fix/unify-image-edit-to-pro-image` (古いブランチ) から分岐しており、`develop` との差分にコンフリクトが含まれる
- ローカルでは `npm test` が通っていたため、コンフリクトに気付かなかった

**影響**: CI が一切トリガーされず (`statusCheckRollup: []`)、マージ不可能な PR が「レビュー完了」と報告された。

**必要なフック**: `PostToolUse` で `gh pr create` 検出時に `gh pr view --json mergeable` を自動チェック。CONFLICTING なら即エラー。

### 欠陥 5: GitHub PR レビューコメントの未処理

**事象**: Copilot が PR #421 に4件のインラインレビューコメントを投稿したが、Claude Code はこれを読まずに「ダブルレビュー完了」と報告した。

**Copilot 指摘の4件**:
1. `package-lock.json` が `^1.29.0` のまま (exact pin されていない)
2. HTTPS レガシー URI がガードをすり抜ける (code-reviewer/Codex と同じ指摘)
3. `file` + `uri` 同時指定時に `uri` が無視される
4. `instrumentation.ts` の `GCLOUD_PROJECT` フォールバック不足

**原因**:
- ダブルレビュー (code-reviewer + Codex CLI) はローカルで実行したが、GitHub 上の Copilot レビューは別チャネル
- `pr-ci-review-gate.sh` は `reviewDecision` (人間のApprove/Request Changes) を見るが、**bot のインラインコメントは reviewDecision に含まれない**
- Claude Code の `PreToolUse:Bash` フックが PR レビューコメント数を表示 (header に `[review] PR #421 レビューコメント: 5件`) しているが、**これはinformationalのみで、未解決コメントがあってもブロックしない**

**影響**: GitHub 上のレビュー指摘が無視されたまま「レビュー完了」と報告。3件の未修正バグ + 1件の未修正 lock file が残った。

**必要なフック**: PR push 後に `gh api repos/.../pulls/{N}/comments` を読み、未解決コメントがゼロになるまでマージをブロック。

### 欠陥 6: Stacked PR のベースブランチ管理

**事象**: PR #421 (fix/420) を修正してプッシュした後、PR #422 (test/363) のベースとの差分が発生。rebase 時に stash が必要になり、ファイルの状態が不安定になった。

**原因**:
- Stacked PR (PR B が PR A をベースにする) の場合、PR A への追加コミットは PR B の rebase を必要とする
- Claude Code には stacked PR の自動 rebase フックがない
- `git checkout` でブランチを切り替える際、未コミットの変更が他ブランチに漏れる

**影響**: ブランチ間のファイル状態が混在し、どのブランチにどの修正が適用されているか不明確になった。

### 欠陥 7: package-lock.json のコミット漏れ

**事象**: `package.json` で `@google/genai` を `1.29.0` (exact pin) に変更したが、`package-lock.json` がコミットに含まれなかった。

**原因**:
- `npm install` は実行したが、`package-lock.json` を明示的に `git add` しなかった
- コミット時に `git add` で個別ファイルを指定する方式では、`package-lock.json` のような副次的な変更が漏れやすい
- フックで `package.json` 変更時に `package-lock.json` の差分を検出する仕組みがない

---

## 技術的制約

Claude Code の hook システムには以下の制約がある:

1. **フックイベントは固定**: `SessionStart`, `PreToolUse`, `PostToolUse`, `TaskCompleted`, `Stop`, `PreCompact` のみ。カスタムイベントは追加不可。
2. **プランファイルの構造解析**: フックはシェルスクリプトなので、Markdown の構造解析は `grep` / `awk` ベースになる。
3. **ExitPlanMode は既存のツール**: `PreToolUse` のマッチャーで `ExitPlanMode` を指定すれば、プラン承認前にフックを発火可能。

---

## 結論

**2つのフェーズで構造的欠陥が発見された:**

### 計画フェーズ (欠陥 1-3)
委任ルールは `delegation.md` に正しく記述されているが、プランモード中は全ての強制フックが免除またはアドバイザリーのみ。ルールは LLM の「知識」としてのみ存在し、プロセスの「ゲート」として機能していない。

### 実装フェーズ (欠陥 4-7)
PR 作成後のコンフリクト検出、GitHub レビューコメント処理、stacked PR 管理、lock file 追跡が全て手動依存。自動化されたゲートが存在しない。

### 優先度付き修正リスト

| 優先度 | 修正 | 対象欠陥 |
|--------|------|---------|
| **P0** | `ExitPlanMode` フックで委任構成を検証 | 欠陥 1-3 |
| **P0** | `gh pr create` 後に `mergeable` 自動チェック | 欠陥 4 |
| **P1** | PR push 後に GitHub レビューコメント未解決チェック | 欠陥 5 |
| **P1** | `package.json` 変更時に `package-lock.json` 差分検出 | 欠陥 7 |
| **P2** | Stacked PR の自動 rebase フック | 欠陥 6 |
| **P2** | アドバイザリーフックのハードブロック化 | 欠陥 3 |

---

*Generated by Claude Code — Issue #420 planning + implementation retrospective (2026-04-08)*
