# Claude Code 構成ハンドオフドキュメント（Codex向け）

作成日: 2026-03-10
目的: Codex が Claude Code の現在の設定・強み・ワークフローを理解し、両者の分担を最適化するための参照資料

---

## 1. ファイル構成と絶対パス一覧

### 1.1 Rules（5ファイル — Claude Code の行動規約）

| ファイル | 絶対パス | 行数 | 内容 |
|---------|---------|------|------|
| delegation.md | `/Users/teradakousuke/.claude/rules/delegation.md` | ~145 | **エージェント並列実行 & Codex委任の3経路（A/B/C）、Claude Code 60% / Codex 40% の分担定義** |
| git-workflow.md | `/Users/teradakousuke/.claude/rules/git-workflow.md` | ~49 | Git/CI/CD規約、PR粒度、follow-up fix制限、soak time、post-merge検証 |
| quality.md | `/Users/teradakousuke/.claude/rules/quality.md` | ~58 | 品質検証、Operationally Readyチェックリスト、repo最低基準 |
| coding-style.md | `/Users/teradakousuke/.claude/rules/coding-style.md` | ~20 | コーディング規約（イミュータブル、関数50行未満等） |
| testing.md | `/Users/teradakousuke/.claude/rules/testing.md` | ~24 | テスト要件（カバレッジ80%、TDD、反証可能性） |

### 1.2 Memory（4ファイル — 永続的な学習・知識）

| ファイル | 絶対パス | 内容 |
|---------|---------|------|
| MEMORY.md | `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/MEMORY.md` | メインメモリ（プロファイル、分担比、最適化履歴） |
| codex-delegation-skills.md | `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/codex-delegation-skills.md` | Codex委任スキルマップ（Tier S/A/B/C、技術スタック別） |
| skills-map.md | `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/skills-map.md` | Skills/Agents/Plugins/Hooks の完全索引 |
| architecture-decisions.md | `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/architecture-decisions.md` | アーキテクチャ決定記録 |

### 1.3 Scripts（3ファイル — 自動化スクリプト）

| ファイル | 絶対パス | 用途 |
|---------|---------|------|
| codex-parallel.sh | `/Users/teradakousuke/.claude/scripts/codex-parallel.sh` | Codex CLI 単一タスク委任（worktree作成→exec→結果出力）+ レビューモード |
| codex-orchestrate.sh | `/Users/teradakousuke/.claude/scripts/codex-orchestrate.sh` | 複数タスク並列オーケストレーター（tasks.json→最大3並列worktree） |
| context-monitor.py | `/Users/teradakousuke/.claude/scripts/context-monitor.py` | コンテキストウィンドウ監視 |

### 1.4 Settings（メイン設定ファイル）

| ファイル | 絶対パス | 内容 |
|---------|---------|------|
| settings.json | `/Users/teradakousuke/.claude/settings.json` | 権限、環境変数、Hooks定義 |

### 1.5 Hooks（有効16 + 無効12）

**有効な Hooks（`settings.json` に登録済み）:**

| Hook | 絶対パス | トリガー | 種別 |
|------|---------|---------|------|
| auto-init-permissions.sh | `/Users/teradakousuke/.claude/hooks/auto-init-permissions.sh` | SessionStart | 初期化 |
| protect-branches.sh | `/Users/teradakousuke/.claude/hooks/protect-branches.sh` | PreToolUse(branch delete) | Git安全 |
| git-push-guard.sh | `/Users/teradakousuke/.claude/hooks/git-push-guard.sh` | PreToolUse(git push) | Git安全 |
| git-commit-guard.sh | `/Users/teradakousuke/.claude/hooks/git-commit-guard.sh` | PreToolUse(git commit) | Git安全 |
| pr-guard.sh | `/Users/teradakousuke/.claude/hooks/pr-guard.sh` | PreToolUse(gh pr create) | PR品質 |
| audit-docker-build-args.sh | `/Users/teradakousuke/.claude/hooks/audit-docker-build-args.sh` | PreToolUse(docker build) | セキュリティ |
| enforce-architecture-layers.sh | `/Users/teradakousuke/.claude/hooks/enforce-architecture-layers.sh` | PreToolUse(domain/core編集) | アーキテクチャ |
| enforce-issue-close-verification.sh | `/Users/teradakousuke/.claude/hooks/enforce-issue-close-verification.sh` | PreToolUse(gh issue close) | 品質 |
| enforce-seed-data-verification.sh | `/Users/teradakousuke/.claude/hooks/enforce-seed-data-verification.sh` | PreToolUse(seed data編集) | データ品質 |
| track-agent-team.sh | `/Users/teradakousuke/.claude/hooks/track-agent-team.sh` | PostToolUse(Agent) | 監視 |
| enforce-ci-check.sh | `/Users/teradakousuke/.claude/hooks/enforce-ci-check.sh` | PostToolUse(gh pr create) | CI検証 |
| post-deploy-verify.sh | `/Users/teradakousuke/.claude/hooks/post-deploy-verify.sh` | PostToolUse(deploy) | デプロイ検証 |
| verify-test-falsifiability.sh | `/Users/teradakousuke/.claude/hooks/verify-test-falsifiability.sh` | PostToolUse(test file edit) | テスト品質 |
| enforce-domain-naming.sh | `/Users/teradakousuke/.claude/hooks/enforce-domain-naming.sh` | PostToolUse(domain/core編集) | 命名規約 |
| enforce-endpoint-dataflow.sh | `/Users/teradakousuke/.claude/hooks/enforce-endpoint-dataflow.sh` | PostToolUse(API route編集) | データフロー |
| enforce-doc-update-scope.sh | `/Users/teradakousuke/.claude/hooks/enforce-doc-update-scope.sh` | PostToolUse(docs編集) | ドキュメント |

**無効な Hooks（`_unused/` に退避済み — 絶対パス: `/Users/teradakousuke/.claude/hooks/_unused/`）:**
enforce-push-strategy, enforce-commit-format, enforce-lint-after-edit, enforce-zero-tolerance-precommit, verify-completion-before-pr, enforce-cicd-setup, enforce-issue-reference-on-commit, enforce-issue-reference-on-pr, enforce-report-verification, suggest-skills-on-prompt, enforce-tdd-order, enforce-codex-review, enforce-parallel-agents, enforce-worktree-freshness, enforce-ci-parity-before-pr, warn-existing-issue-dismissal

### 1.6 Codex側の関連ファイル

| ファイル | 絶対パス | 内容 |
|---------|---------|------|
| config.toml | `/Users/teradakousuke/.codex/config.toml` | Codex設定（gpt-5.4, trusted repos, MCP servers） |
| claude-code-delegation SKILL | `/Users/teradakousuke/.codex/skills/claude-code-delegation/SKILL.md` | Claude Codeからの委任タスク品質ゲート |
| codex-delivery-governance SKILL | `/Users/teradakousuke/.codex/skills/codex-delivery-governance/` | PR粒度・CI・release readiness統制 |
| AGENTS.md | `/Users/teradakousuke/.claude/plugins/marketplaces/claude-code-harness-marketplace/codex/AGENTS.md` | Codex用ハーネスガイド |

### 1.7 監査レポート

| ファイル | 絶対パス | 内容 |
|---------|---------|------|
| 監査レポート | `/Users/teradakousuke/Developer/commit-strategy-audit-2026-03-10.md` | 3ヶ月間27repo横断監査（fix/feat比、CI失敗パターン、改善提案） |

---

## 2. Claude Code の強み（Codex側が理解すべき点）

### 2.1 エージェントチームによる有機的並列実装

Claude Code は最大5-7のサブエージェントを同時起動し、**相互にコンテキストを共有しながら**実装できる。これはCodexのworktree分離では再現できない。

```
Claude Code メインプロセス
├── Agent(planner): 設計書作成 → 結果を他Agentが即参照
├── Agent(code-reviewer): 実装中のコードを動的レビュー
├── Agent(tdd-guide): テストを先行作成 → 実装Agentが参照
├── Agent(security-reviewer): セキュリティ観点で並行チェック
└── メイン: 全Agentの結果を統合して最終判断
```

**Codexのworktreeとの違い:**
- Codex: 各worktreeは完全分離。Agent間の情報共有は不可
- Claude Code: 全AgentがメインプロセスのFork。結果が即座に他Agentの判断に反映される

### 2.2 Hooks による自動品質ゲート

Claude Code は `settings.json` の Hooks で、**ツール実行の前後に自動検証**を挟める。これはCodexの `.codex/rules/` よりも強力な強制力を持つ。

主要なガードレール:
- `git commit` → commit-guard が conventional commit形式を検証
- `git push` → push-guard がブランチ保護を検証
- `gh pr create` → PR-guard がCI結果を検証
- `docker build` → build-arg にhttp://が含まれていないか検証
- domain/core ファイル編集 → アーキテクチャレイヤー違反を検出
- テストファイル編集 → テスト反証可能性を自動検証
- API route 編集 → エンドポイントのデータフロー一貫性を検証

### 2.3 60以上のSkills

Claude Code は60以上のカスタムスキルを持ち、ユーザーのリクエストに応じて自動的に適切なスキルを提案・実行する。完全な索引は以下を参照:
- `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/skills-map.md`

### 2.4 26のカスタムエージェント

言語特化（TypeScript, Python, Go, Swift）、ドメイン特化（DB, WebSocket, Security, Terraform）、ワークフロー特化（planner, code-reviewer, tdd-guide）の26エージェントが利用可能。

### 2.5 設定の環境変数

```json
{
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001"
}
```
- エージェントチーム機能が有効
- 軽量タスクにはHaiku 4.5を使用

---

## 3. 現在の分担（Claude Code 60% : Codex 40%）

### 3.1 Claude Code 60%（設計・並列実装・統括）

| 責務 | 理由 |
|------|------|
| ユーザー対話・要件理解 | リアルタイム応答が必要 |
| アーキテクチャ設計 | トレードオフ判断、planner/architect エージェント |
| エージェントチーム並列実装 | 有機的協調（相互参照・動的レビュー） |
| セキュリティ判断 | security-reviewer + 人間判断が必要 |
| 最終統合・merge判断 | 全Agentの結果を統合して判断 |

### 3.2 Codex 40%（直列実装・運用・品質）

| 責務 | 理由 |
|------|------|
| 長時間直列タスク | コンパクティング回避。Claude Codeのコンテキストを消費しない |
| worktree並列の機械的タスク | テスト作成、docs更新、follow-up fix、CI修正 |
| GitHub運用 | PR作成・Issue管理・checks確認（MCP github） |
| Supabase運用 | SQL・migration・Edge Function（MCP supabase） |
| 品質監査 | repo_delivery_audit.py定期実行 |
| delivery統制 | merge gate判定、soak time判定 |

### 3.3 委任経路

| 経路 | 方法 | 用途 |
|------|------|------|
| **A** | `codex exec review` | レビュー・セカンドオピニオン |
| **B** | ハンドオーバードキュメント | 大規模実装（ユーザー判断必要） |
| **C** | `codex exec` + worktree | 直列実装・機械的並列タスク |

### 3.4 委任判断フロー

```
タスク受信
├─ 対話・判断が必要? → Claude Code（メイン）
├─ 複数タスクが相互依存? → Claude Code（エージェントチーム）
├─ 創造的・設計的な実装? → Claude Code（planner + architect）
├─ レビュー/セカンドオピニオン? → codex exec review（経路A）
├─ 長時間直列（コンパクティングリスク）? → Codex CLI（経路C）
├─ 機械的・独立・大量? → codex-orchestrate.sh（経路C・並列）
├─ GitHub/Supabase操作? → Codex CLI
├─ ユーザー判断が必要な大規模実装? → ハンドオーバー（経路B）
└─ 調査が必要? → Claude Code Explore エージェント
```

---

## 4. 監査で判明した問題と対策（2026-03-10）

### 4.1 数値サマリー
- 27 repo / 2,592 commits（3ヶ月）
- fix 883件 = feat 474件の **1.86倍**
- test コミット **1.3%**（目標: 10%以上）
- workflow未整備 **11 repo**
- merge commit **500件**（19.3%）

### 4.2 追加されたルール

**git-workflow.md に追加:**
- PR粒度ルール（1PR=1意図、branch名とtype一致）
- follow-up fix制限（2本連続でfeature freeze）
- soak time（develop→main前に半日以上）
- post-merge検証（CIをmerge gateとして使用）

**quality.md に追加:**
- Operationally Readyチェックリスト（8項目）
- repo最低基準（workflow 0件は開発進行前にCI導入）

**delegation.md に追加:**
- ハンドオーバーテンプレートに品質ゲート6項目

### 4.3 数値目標（次回監査時）
- fix/feat比: 1.86倍 → **1.0倍以下**
- test commit比率: 1.3% → **10%以上**
- follow-up fix連鎖: 3本以上 → **2本以内で収束**
- workflow未整備repo: 11件 → **セキュリティ/決済系は0件**

---

## 5. Codexに期待する最適化観点

### 5.1 Codex側のスキル・ルールの最適化
- `claude-code-delegation` SKILL と `codex-delivery-governance` SKILL の内容が、Claude Code側のルール（delegation.md, git-workflow.md, quality.md）と**整合しているか**確認
- Codex側の `default.rules` や `config.toml` が、上記の分担比に適した設定になっているか確認

### 5.2 分担の境界の明確化
- Claude Codeの「エージェントチーム並列」とCodexの「worktree並列」が**重複しない**ように境界を整理
- 「長時間直列タスク」の定義を具体化（何分以上をCodexに委任するか等）

### 5.3 ワークフローの統合テスト
- `codex-parallel.sh` と `codex-orchestrate.sh` が実際に動作するか検証
- Claude Code → Codex CLI → GitHub PR の一気通貫フローの動作確認

### 5.4 品質ゲートの統一
- Claude Code側のHooksとCodex側のRulesが**同じ品質基準**を適用しているか
- 特に「1PR=1意図」「feat PRにtest同梱」「follow-up fix起源明記」が両方で強制されているか

---

## 6. 参照すべきファイル一覧（優先度順）

### 最重要（分担・ワークフロー定義）
1. `/Users/teradakousuke/.claude/rules/delegation.md` — 分担比・委任経路・判断フロー
2. `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/codex-delegation-skills.md` — Codex委任スキルマップ
3. `/Users/teradakousuke/Developer/commit-strategy-audit-2026-03-10.md` — 監査レポート

### 品質・規約
4. `/Users/teradakousuke/.claude/rules/git-workflow.md` — Git/CI/CD規約
5. `/Users/teradakousuke/.claude/rules/quality.md` — 品質・検証ルール
6. `/Users/teradakousuke/.claude/rules/coding-style.md` — コーディング規約
7. `/Users/teradakousuke/.claude/rules/testing.md` — テスト要件

### Claude Code固有の仕組み
8. `/Users/teradakousuke/.claude/settings.json` — Hooks・権限・環境変数
9. `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/skills-map.md` — Skills/Agents/Plugins索引
10. `/Users/teradakousuke/.claude/projects/-Users-teradakousuke-Developer/memory/MEMORY.md` — メインメモリ

### スクリプト・Codex連携
11. `/Users/teradakousuke/.claude/scripts/codex-parallel.sh` — 単一タスク委任スクリプト
12. `/Users/teradakousuke/.claude/scripts/codex-orchestrate.sh` — 並列オーケストレーター
13. `/Users/teradakousuke/.codex/skills/claude-code-delegation/SKILL.md` — Codex側の委任タスク品質ゲート
14. `/Users/teradakousuke/.codex/config.toml` — Codex設定
