# Claude Code Skills

[Claude Code](https://claude.com/claude-code)（Anthropic 公式 CLI）のためのスキル・ルール・フック集です。

26 のカスタムスキル、59 の hook スクリプト（+ 7 ゲートモードモジュール）、5 つのルールセット、6 つのユーティリティスクリプトを含む、本番環境レベルの Claude Code 設定を提供します。

[English](README.md) | **日本語**

## クイックスタート

```bash
git clone https://github.com/terisuke/claude-code-skills.git
cd claude-code-skills
chmod +x setup.sh
./setup.sh
```

インストール後、Claude Code を再起動してください。

## リポジトリ構成

```
claude-code-skills/
├── skills/           # 26 カスタムスキル定義 (SKILL.md + scripts + references)
├── rules/            # 5 グローバルルール (コーディング規約, Git, 品質, テスト, 委任)
├── hooks/            # 59 hook スクリプト + 7 ゲートモードモジュール (品質ゲート, 安全ガード, ワークフロー強制)
├── scripts/          # 6 ユーティリティ (Codex 連携, PR レビュー, コンテキスト監視)
├── setup.sh          # ワンコマンドインストール
├── settings.json     # 設定テンプレート (パス等サニタイズ済み)
├── README.md         # 英語版 README
└── README.ja.md      # 日本語版 README (本ファイル)
```

## アーキテクチャ決定記録 (ADR)

設計決定は `docs/adr/` に ADR として記録されています。

| ADR | タイトル | ステータス |
|-----|---------|----------|
| [001](docs/adr/001-posttooluse-quality-loop.md) | PostToolUse Quality Loop | Accepted |
| [002](docs/adr/002-pointer-design-principle.md) | CLAUDE.md Pointer Design Principle | Accepted |
| [003](docs/adr/003-feedback-speed-hierarchy.md) | Feedback Speed Hierarchy | Accepted |
| [004](docs/adr/004-codex-delegation-model.md) | Codex Large-Scale Delegation Model | Accepted |
| [005](docs/adr/005-plans-json-migration.md) | Plans.md → JSON Migration | Rejected |

新しい ADR を追加するには[テンプレート](docs/adr/template.md)を使用してください。

## 参考文献

| ドキュメント | 説明 |
|------------|------|
| [Harness Engineering Best Practices 2026](docs/references/harness-engineering-best-practices-2026.md) | 本リポジトリの設計哲学の基盤となる記事の要約 |
| [The Complete Guide to Building Skills for Claude](docs/references/The-Complete-Guide-to-Building-Skills-for-Claude.pdf) | Anthropic 公式ガイド — スキル構造、プログレッシブディスクロージャー、テスト、配布（[要約](docs/references/anthropic-skill-guide-summary.md)） |

詳細は [docs/references/](docs/references/) を参照。

## サードパーティ依存

以下のサードパーティスキルフレームワークと連携します。このリポジトリには**同梱されていません** — `setup.sh` が自動インストールします。

| パッケージ | 作者 | ライセンス | 用途 | インストール |
|-----------|------|----------|------|------------|
| [gstack](https://github.com/garrytan/gstack) | Garry Tan (YC CEO) | MIT | Think/Plan フェーズ: /office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /retro + QA/ブラウザツール | `git clone` + `./setup` |
| [ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | nextlevelbuilder | Open Source | UI/UX デザインインテリジェンス: 67 スタイル, 96 パレット, 57 フォントペアリング, 13 テックスタック | `npm install -g uipro-cli` + `uipro init --ai claude` |

### ハイブリッドアーキテクチャ

```
Think → Plan (gstack)
  /office-hours → /plan-ceo-review → /plan-eng-review → /plan-design-review

Build → Review → Ship (カスタムスキル + hooks)
  code-reviewer, review-loop, e2e, bugfix + 57 hook スクリプト

Reflect (gstack)
  /retro
```

## スキル一覧

### 開発ワークフロー
| スキル | 機能 | トリガー |
|-------|------|---------|
| `code-reviewer` | OWASP セキュリティチェック付き PR レビュー | "review this PR", "code review" |
| `review-loop` | CI グリーン + レビュー LGTM まで自動ループ | /review-loop |
| `bugfix` | 根本原因分析 + 全インスタンス修正 | /bugfix [説明] |
| `tdd-workflow` | RED-GREEN-REFACTOR サイクル強制 | "write tests first", "TDD" |
| `test-falsify` | テストが宣言されたバグを実際に検出するか検証 | /test-falsify |
| `git-commit-helper` | Conventional Commit メッセージ生成 | "commit this" |
| `changelog-generator` | Git 履歴からユーザー向けリリースノート生成 | "create changelog" |

### アーキテクチャ & デザイン
| スキル | 機能 | トリガー |
|-------|------|---------|
| `modern-architecture` | DDD + Clean Architecture + CQRS パターン | "clean architecture", "DDD" |
| `senior-architect` | アーキテクチャ図付きシステム設計 | "design the system" |
| `senior-frontend` | React/Next.js/Tailwind 開発 | "create component" |
| `senior-backend` | Python/Node.js/Go バックエンド開発 | "design an API" |
| `senior-fullstack` | フルスタックスキャフォールディング | "scaffold a new project" |
| `ui-skills` | Tailwind CSS 制約とアクセシビリティ | "review this component" |
| `ui-design-system` | デザイントークン生成 | "generate design tokens" |

### DevOps & インフラ
| スキル | 機能 | トリガー |
|-------|------|---------|
| `gcp-deploy-guardian` | GCP デプロイ失敗防止 | docker build, gcloud deploy |
| `supabase-nextjs-debugger` | Supabase + Next.js バグ診断 | "Vercel 404", "RLS error" |
| `security-review` | OWASP Top 10 脆弱性監査 | "security review" |

### 生産性
| スキル | 機能 | トリガー |
|-------|------|---------|
| `agent-orchestrator` | マルチエージェントチーム構成 | 3+ 並列タスク |
| `skill-creator` | インタラクティブなスキル作成ガイド | "create a skill" |
| `brainstorming` | 実装前のアイデア探索 | "brainstorm", "let's think through" |
| `file-organizer` | ディレクトリ整理と重複排除 | "organize my files" |
| `developer-growth-analysis` | コーディングパターン分析 + Slack レポート | "analyze my growth" |
| `adk-engineer` | Google ADK エージェント実装 | "ADK agent" |
| `ux-researcher-designer` | ペルソナ生成、ジャーニーマッピング | "create persona" |
| `gws-workspace` | Google Workspace CLI 操作 | "Google Drive", "Sheets" |
| `context7-skills` | Context7 CLI スキル管理 | "search skills", "ctx7" |

## エージェントアーキテクチャ & Codex 委任

このシステムの最大の差別化要素は、**マルチエージェントオーケストレーション**と Codex CLI への自動委任です。

### Claude Code + Codex CLI ハイブリッドモデル

```
Claude Code (60%) — 設計、並列実装、統括、ユーザー対話
  └─ 強み: エージェントチーム、リアルタイム判断、コンテキスト共有型協調

Codex CLI (40%) — 直列実装、運用、品質監査
  └─ 強み: worktree 分離、長時間自律実行、GitHub/Supabase 統合
```

### サブエージェント & エージェントチームシステム

| パターン | 使用場面 | 例 |
|---------|---------|-----|
| **単一エージェント** | スコープが明確な単独タスク | 「この lint エラーを修正して」 |
| **並列エージェント (2-4)** | 依存関係のない独立タスク | フロントエンド + バックエンドの並列変更 |
| **エージェントチーム (5-7)** | クロスレビュー付きの複雑なマルチファイル機能 | 新機能 + テスト + ドキュメント + レビュー |
| **Agent Team (worktree)** | 軽量な1-2ファイル変更、ドキュメント | Dockerfile修正、設定変更、docs作成 |
| **Codex 委任** | 長時間、機械的、5ターン超のタスク | 大量テスト作成、大規模リファクタ |

`agent-orchestrator` スキルがチーム構成、ウェーブ実行、クロスレビューを管理します。

### Codex 委任の 3 経路

| 経路 | 用途 | コマンド |
|------|------|---------|
| **A: レビュー** | コードレビュー、セカンドオピニオン | `codex exec review --base <branch>` |
| **B: ハンドオーバー** | 大規模実装（ユーザー判断が必要） | ハンドオーバードキュメント作成 → ユーザーが Codex に渡す |
| **C: 並列実行** | 独立タスクを分離 worktree で実行 | `codex-parallel.sh` または `codex-orchestrate.sh` |

### コンテキスト予算ゲート（自動強制）

hook スクリプトが委任ルールを自動的に強制します:

```
タスク受信
├─ 2+ 独立タスク? → Agent Team（TeamCreate）
├─ 1タスク + 長時間 + 自律的 + 大規模? → Codex CLI 経路C（1タスク限定）
├─ 読み込みファイル 3 未満? → Claude Code（自力実行）
├─ テスト/ドキュメント作成（単一タスク）? → Codex CLI 経路C
├─ 予想 5 ターン超（単一タスク）? → Codex CLI 経路C
└─ リアルタイム判断が必要? → Claude Code（メイン）
```

**重要**: Codex CLI は**1タスク限定**。複数の独立タスクは Agent Team (TeamCreate) を使用し、Codex には委任しない。

| hook | トリガー | アクション |
|------|---------|----------|
| `context-budget-read-gate.sh` | Read ツール | 3+ ファイルで警告、6+ で強い警告 |
| `context-budget-write-gate.sh` | Write ツール | テスト/ドキュメント作成検出 → Codex 提案 |
| `context-budget-edit-write-gate.sh` | Edit/Write | 多数ソースファイル読み込み後の編集をブロック |
| `context-budget-agent-gate.sh` | Agent ツール | foreground実装Agent 2つ目をブロック、1つ目に警告、background/TeamCreate強制 |
| `codex-task-gate.sh` | Bash (Codex実行) | 2回目以降の Codex CLI 呼び出しをブロック（同時1タスク制限） |
| `codex-task-release.sh` | PostToolUse Bash | Codex タスク完了後にカウンターを解放（順次再利用を可能に） |

### ユーティリティスクリプト

| スクリプト | 用途 |
|-----------|------|
| `codex-parallel.sh` | 単一タスク Codex 実行（sandbox 自動選択） |
| `codex-orchestrate.sh` | マルチタスク並列実行（JSON/CSV 入力、worktree 分離） |
| `check-pr-reviews.sh` | PR レビュータイムスタンプと最新 push の照合 |
| `verify-pr-review.sh` | マージ前のレビューカバレッジ検証 |
| `context-monitor.py` | コンテキストウィンドウ使用量とトークン消費の監視 |

## レビューパイプライン（PR マージゲート）

全ての PR は**マルチゲートレビューパイプライン**を通過しなければマージできません。hook による自動強制のため、手動ステップは不要です。

```
PR マージ可能？
│
├─ Gate 1: CI 全グリーン？ ──────────────── block-merge-without-ci.sh
│  └─ 全 GitHub Actions チェックが ✅（pending/failed は不可）
│
├─ Gate 2: 最新 push 後のレビュー？ ──────── block-merge-without-review.sh
│  └─ review.submittedAt > 最終 push 時刻（古いレビューは拒否）
│
├─ Gate 3: レビュー検証済み？ ───────────── pr-ci-review-gate.sh (LIGHT tier 3-pass OR)
│  ├─ Pass A: code-reviewer エージェント完了 (review-status.json)
│  ├─ Pass B: CRITICAL/HIGH 指摘なし (pending-review-comments.json)
│  └─ Pass C: 手動検証 (pr-review-lock.json verified=true)
│
├─ Gate 4: 未解決コメント？ ──────────────── enforce-review-reading.sh
│  └─ 全 CRITICAL/HIGH レビュー指摘が対処済み
│
└─ Gate 5: レビュー注入 ────────────────── inject-claude-review-on-checks.sh
   └─ `gh pr checks` / `gh pr merge` 時にレビューコメントを自動取得
```

### Tier 制レビューシステム

レビュー要件は変更内容に応じて自動調整されます:

| Tier | 対象 | 必要なレビュー | 判定基準 |
|------|------|--------------|---------|
| **FULL** | ソースコード変更 | code-reviewer + Codex CLI | `src/`, `lib/`, `app/`, `*.ts`, `*.py` 等の変更あり |
| **LIGHT** | CI/設定/ドキュメントのみ | code-reviewer のみ | `.github/workflows/`, `*.md`, `Dockerfile`, `*.yml` 等のみ |
| **EXEMPT** | ブランチ名で判定 | 不要 | `docs/*`, `chore/*`, `ci/*` ブランチ |

CI ワークフローの変更に Codex CLI のセカンドオピニオンは不要です。

### 外部レビューがない場合

PR に GitHub レビューがない場合（ソロ開発など）、**ローカルレビューパイプライン**にフォールバックします:

1. **`code-reviewer` スキル** — OWASP セキュリティチェック付き自動 PR 分析
2. **Codex CLI 経路A**（FULL tier のみ） — 独立したセカンドオピニオン: `codex exec review --base <branch>`
3. **両方パス**（FULL tier）または手順1のみ（LIGHT tier）でレビュー完了

変更のリスクレベルに応じた適切なレビュー深度が保証されます。

### ハウスキーピング

マージ済み/クローズ済みの PR はロック状態から自動クリーンアップされます:

- **STOP hook**: GitHub API で state 確認し、merge/closed エントリを自動除去
- **手動クリーンアップ**: `GATE_MODE=CLEANUP bash hooks/pr-ci-review-gate.sh`

### PR ライフサイクル hook

| フェーズ | hook | アクション |
|---------|------|----------|
| **PR 作成** | `pr-guard.sh` | ベースブランチ、Issue 参照、コンフリクトチェック |
| **PR 作成** | `pr-ci-review-gate.sh` (PRE_CREATE) | レビューパイプライン準備確認 |
| **Push 後** | `pr-ci-review-gate.sh` (POST_PUSH) | レビューロック設定（新しい push で古いレビューを無効化） |
| **マージ前** | `pr-ci-review-gate.sh` (PRE_MERGE) | CI green + レビュー LGTM なしでマージをブロック |
| **マージ前** | 上記 5 ゲート全て | 全パスしなければマージをブロック |
| **マージ後** | `post-merge-close-issues.sh` | リンクされた Issue を自動クローズ |
| **セッション終了** | `pr-ci-review-gate.sh` (STOP) | 未検証 PR について警告 |


## 設計哲学

本リポジトリは3つの基礎原則に基づいています。

### 1. Harness Engineering Best Practices (2026)

[ベストプラクティス記事](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/)に基づくアーキテクチャ:

| 原則 | 実装 | カバレッジ |
|------|------|-----------|
| LLMプロンプトより決定論的ツール | 59 hook スクリプト + 7 ゲートモードモジュール | 98%+ hook カバレッジ |
| フィードバック速度階層 | PostToolUse(ms) > pre-commit > CI(min) > レビュー(hr) | ADR-003 |
| ポインタベースドキュメント | ルール各50行以内（合計122行）、ADR/hookへポインタ | ADR-002 |
| 設定ファイル保護 | `protect-linter-config.sh` でエージェントのルール緩和をブロック | PreToolUse |
| 計画-実行分離 | Plans.md + plan mode + planner エージェント | TaskCreate/Update |
| Stop時E2Eテスト | `stop-test-gate.sh` で変更関連テスト実行 | Stop hook |
| Git = セッション間ブリッジ | `enforce-memory-update-on-commit.sh` | PostToolUse |
| Claude Code + Codex ハイブリッド | 60/40 分担、自動委任 | ADR-004 |

**ベストプラクティス記事カバー率: 88% (36項目中32項目)**

### 2. Epic #130:「実装 ≠ 動作」

11/18 のhook (61%) が「実装済み」だが実際には発火しなかった事故から生まれた運用原則:

> **「コードが存在する」と「システムが動作する」は別の検証ステップ。コードレビューだけでは運用の正しさを保証できない。**

以下で強制:
- **4段階検証**: コード存在 → 構文OK → settings.json登録 → 実際に発火
- **`delivery_score.py`**: 定量品質スコア（hookカバレッジ、CI合格率、レビュー遵守率）
- **`validate-hook-deployment.sh`**: ソース ↔ デプロイ ↔ 登録の整合性チェック
- **CI/CD**: shellcheck + JSON validation + syntax checking（全PR）

**Epic #130 前**: hookゲート動作率 39% (7/18) → **後**: 98%+ (59/59 hooks 登録 + デプロイ済み)

### 3. Delivery Quality Score

`python3 scripts/delivery_score.py` で定量品質評価:

```
==================================================
  Delivery Quality Score: claude-code-skills
==================================================
  Total: 99.0/100 (A+)
  hook_coverage: 96.5 / ci_pass_rate: 100.0
  soak_time: 100.0 / review_compliance: 100.0
==================================================
```

`--json` オプションでCI/自動化統合可能。

## 既知の問題 & ロードマップ

Epic #130 レビュー (2026-03-24) の全 P1-HIGH Issue は解決済みです。
P2-MEDIUM Issue #136-#147 も後続 PR で解決済みです。現在のオープン項目:

| Issue | 説明 | ステータス |
|-------|------|----------|
| [#161](../../issues/161) | `delegation.md` 327→50行圧縮（ADR-002、#107 再オープン） | 本リリースで修正済み |

## Hook システム（59 スクリプト + 7 ゲートモードモジュール）

### セッション初期化
- `auto-init-permissions.sh` — セッション開始時にパーミッションを自動初期化
- `context-budget-reset.sh` — セッション開始時にカウンターリセット（`fg_impl_agent_count` 含む）
- `reset-factcheck.sh` — セッション開始時にファクトチェック状態をリセット
- `enforce-branch-workflow.sh` — develop ブランチ自動作成、フィーチャーブランチワークフロー強制
- `validate-no-local-hooks.sh` — セッション開始時に hook 上書きが存在しないことを検証
- `validate-hook-deployment.sh` — 全 hook のインストールと settings.json への登録を検証

### 品質ゲート（マージ前）
- `block-merge-without-ci.sh` — CI 全チェックグリーンなしでマージをブロック
- `block-merge-without-review.sh` — 最新 push 後のレビューなしでマージをブロック
- `pr-ci-review-gate.sh` — 6 モードゲート (PRE_CREATE / PRE_MERGE / POST_PUSH / STOP / VERIFY / CLEANUP) Tier 制レビュー対応
- `pr-merge-claude-review-gate.sh` — 5 サブゲート Claude レビュー強制
- `inject-claude-review-on-checks.sh` — `gh pr checks` / `gh pr merge` 時にレビューコメントを自動取得
- `pr-guard.sh` — ベースブランチ、Issue 参照、コンフリクトチェック
- `task-completion-gate.sh` — 早期タスク完了をブロック（CI pending または CRITICAL/HIGH 指摘あり）
- `stop-test-gate.sh` — セッション終了前に change-related test gate 実行（docs/config-only はスキップ、必要時は full suite fallback、stop_hook_active ガード付き）

### 安全ガード
- `protect-branches.sh` — 保護ブランチの削除防止
- `block-manual-merge-ops.sh` — cherry-pick/merge/rebase をブロック（main/master/develop からの同期は許可）
- `git-push-guard.sh` — プッシュ安全チェック
- `git-commit-guard.sh` — コミットメッセージとスコープ検証
- `block-version-downgrade.sh` — 依存パッケージのダウングレード防止
- `audit-docker-build-args.sh` — Docker build args の http:// チェック
- `block-local-hooks-write.sh` — settings.local.json によるグローバル hook 上書きを防止
- `block-codex-mcp.sh` — Codex MCP 使用をブロック、CLI 経由のみ強制 (PreToolUse)
- `block-state-file-tampering.sh` — AI による状態ファイル自己改ざん防止 (Write/Edit)
- `block-state-file-tampering-bash.sh` — AI による状態ファイル自己改ざん防止 (Bash)
- `protect-linter-config.sh` — リンター設定の不正変更を防止

### コンテキスト予算管理
- `context-budget-read-gate.sh` — 3+ ソースファイル読み込みで警告/ブロック
- `context-budget-write-gate.sh` — テスト/ドキュメント作成を検出し Codex 委任提案
- `context-budget-edit-write-gate.sh` — 多数ファイル読み込み後の編集をブロック
- `context-budget-agent-gate.sh` — foreground 実装 Agent の制限（2つ目ブロック）、background/TeamCreate 強制
- `codex-task-gate.sh` — 2回目以降の Codex CLI 呼び出しをブロック（同時1タスク制限）
- `codex-task-release.sh` — Codex タスク完了後にカウンター解放（PostToolUse）

### ワークフロー強制
- `enforce-git-freshness.sh` — リモートより遅れている場合に編集をブロック
- `enforce-factcheck-before-edit.sh` — インフラ変更前にファクトチェック必須（.yml/.md 等の非コードファイルは除外）
- `enforce-factcheck-before-user-request.sh` — 手動操作依頼前にファクトチェック必須
- `enforce-factcheck-github-ops.sh` — `gh issue comment/create`、`gh pr create` 実行前にファクトチェック必須
- `enforce-architecture-layers.sh` — domain/core レイヤー変更を検証
- `enforce-domain-naming.sh` — DDD 命名規則の強制
- `enforce-endpoint-dataflow.sh` — API 変更時のフルデータフロー検証
- `enforce-seed-data-verification.sh` — シードデータの参照ドキュメント照合
- `enforce-issue-close-verification.sh` — Issue クローズ前に受入基準チェック
- `enforce-review-reading.sh` — マージ前に全レビューコメント読了
- `enforce-memory-update-on-commit.sh` — コミット後の MEMORY.md 更新チェック
- `enforce-doc-update-scope.sh` — ドキュメント更新スコープの検証

### アクション後 hook
- `record-code-review.sh` — コードレビュー完了をマージゲートトラッキング用に記録
- `record-codex-review.sh` — Codex CLI レビュー完了を記録（codex-parallel.sh から呼び出し）
- `mark-factcheck-done.sh` — リサーチ後にファクトチェック完了をマーク
- `track-agent-team.sh` — エージェントチームの生成と完了を追跡
- `post-merge-close-issues.sh` — マージ後にリンクされた Issue を自動クローズ
- `post-deploy-verify.sh` — デプロイ後の検証チェック
- `post-lint-format.sh` — ファイル編集後に lint/format チェック実行（PostToolUse Quality Loop）
- `post-pr-create-review-trigger.sh` — PR 作成後にコードレビューを自動トリガー (PostToolUse)
- `workflow-sync-guard.sh` — push 後のワークフロー状態同期
- `verify-test-falsifiability.sh` — テストが宣言されたバグを実際に検出するか検証 (PostToolUse)
- `tool-failure-recovery.sh` — ツール失敗時のエラー回復ガイダンス（PostToolUseFailure）
- `pre-compact-context-save.sh` — コンパクション前に重要コンテキスト（ブランチ、PR、レビュー状態）を保存（PreCompact）

## Hook Matcher 構文

**重要**: Claude Code の `matcher` フィールドは**ツール名の正規表現**のみを受け付けます。式言語ではありません。コマンドレベルのフィルタリングは hook スクリプト内で `stdin` の JSON を解析して行います。

```json
// 正しい — ツール名を正規表現でマッチ
{ "matcher": "Bash" }
{ "matcher": "Edit|Write" }

// 間違い — 発火しない（ツール名に対する正規表現として扱われる）
{ "matcher": "tool == \"Bash\" && tool_input.command matches \"git push\"" }
```

hook スクリプトは `stdin` でツール呼び出しの JSON を受け取り、`tool_input.command` や `tool_input.file_path` を検査してフィルタリングします。

### Exit Code 規約（公式仕様準拠）

| Exit Code | 意味 | PreToolUse の動作 |
|-----------|------|-----------------|
| `0` | 許可 | ツール呼び出しを続行。JSON 出力があれば `hookSpecificOutput` を解析 |
| `2` | ブロック | ツール呼び出しをブロック。`stderr` が Claude にエラーメッセージとして伝達 |
| その他 | 非ブロッキングエラー | `stderr` は verbose モードでのみ表示。実行は続行 |

**重要**: `exit 0` で許可する際、入力 JSON を stdout にエコーバックしないでください。公式パターンは単純に `exit 0` のみです。本リポジトリの全 hook はこの規約に準拠しています。

詳細は[公式 hooks ドキュメント](https://docs.anthropic.com/en/docs/claude-code/hooks)を参照。

## ルール

| ファイル | 目的 |
|---------|------|
| `coding-style.md` | イミュータブル、ファイルサイズ制限、Zod バリデーション、セキュリティチェック |
| `git-workflow.md` | ブランチ保護、PR 粒度、soak time、マージ後検証 |
| `quality.md` | エラーゼロトレランス、完了検証、Docker 制約 |
| `testing.md` | カバレッジ 80%+、TDD ワークフロー、テストレベル定義、反証可能性 |
| `delegation.md` | Claude Code vs Codex CLI 委任ルール、コンテキスト予算ゲート |

---

## Anthropic 公式スキルベストプラクティス

> [The Complete Guide to Building Skills for Claude](https://docs.anthropic.com)（Anthropic, 2026）に基づく

### スキル構造要件

```
skill-name/              # kebab-case、スペースなし、大文字なし
├── SKILL.md             # 必須 — YAML フロントマター + Markdown 指示
├── scripts/             # 任意 — 実行可能コード（決定論的、トークン効率的）
├── references/          # 任意 — 必要に応じてコンテキストに読み込むドキュメント
└── assets/              # 任意 — 出力に使用するテンプレート、フォント、アイコン
```

**スキルフォルダ内に README.md、CHANGELOG.md、補助ドキュメントを置かないこと。**

### プログレッシブディスクロージャー（3 レベル）

1. **YAML フロントマター** — 常にシステムプロンプトに読み込まれる。Claude がスキルを**いつ使うか**判断するための最小限の情報。
2. **SKILL.md 本文** — Claude がスキルが関連すると判断した時に読み込まれる。完全な指示を含む。
3. **references/** — 必要に応じて Claude が参照する追加ファイル。

### フロントマタールール

```yaml
---
name: skill-name          # 必須。kebab-case、"claude"/"anthropic" プレフィックス禁止
description: |             # 必須。[何を] + [いつ] + [機能]。1024 文字以内。
  何をするか。"トリガーフレーズ" で使用。
  使用しない場面: ネガティブトリガー。
allowed-tools: [Read, Bash, Grep]  # 任意。ツールアクセスを制限。
license: MIT               # 任意
metadata:                  # 任意
  author: Your Name
  version: 1.0.0
---
```

**重要: フロントマターに XML アングルブラケット (`< >`) を使用しないこと。** フロントマターは Claude のシステムプロンプトに表示されるため、アングルブラケットは命令インジェクションの危険がある。代わりに `[placeholder]` を使用。

### description フィールドの構造

```
[何をするか] + [いつ使うか] + [主要な機能] + [使用しない場面]
```

**良い例:**
```yaml
description: git diff を分析して Conventional Commit メッセージを生成する。
  変更をステージング中やコミットメッセージ作成時に使用。
  ブランチ戦略やマージコンフリクト解決には使用しない。
```

**悪い例:**
```yaml
description: プロジェクトを支援する。  # 曖昧すぎる、トリガーなし
```

### 指示の書き方ルール

- **命令形**: 「X を実行」「Y を確認」（「X を実行すべき」ではない）
- **具体的かつ実行可能**: `Run python scripts/validate.py --input {filename}`（「データを検証する」ではない）
- **重要な情報を先頭に**: `## Critical` や `## Important` ヘッダーを使用
- **SKILL.md 本文は 500 行以内**: 詳細は `references/` に移動
- **エラーハンドリング**: 失敗時の対処を含める
- **重複なし**: 情報は SKILL.md OR references/ のどちらかに存在、両方には置かない

### 条件付きアテンションタグ

SKILL.md 本文（フロントマターではない）で `<important if="条件">` タグを使用し、関連するセクションに Claude のアテンションを集中させる:

```xml
<important if="本番環境にデプロイする場合">
- Docker ビルドに --platform linux/amd64 を使用
- --update-env-vars を使用（--set-env-vars ではない）
</important>
```

**ルール:**
- 条件は**具体的に**（`if="コードを書いている場合"` は広すぎる）
- 普遍的なルールは**条件なし**のまま
- 80% 以上の場合に適用されるルールはラップしない

### スコープ判定（グローバル vs プロジェクトローカル）

| スコープ | 基準 | パス |
|---------|------|------|
| **グローバル** | テックスタック非依存、全プロジェクトで有用 | `~/.claude/skills/` |
| **プロジェクトローカル** | 特定プロジェクトのサービス/アーキテクチャに依存 | `.claude/skills/` |
| **組織** | チーム全体のポリシー強制 | 管理者デプロイ |

**グローバルスキルはセッションごとの制限（推奨 20-50）にカウントされる。** 迷ったらプロジェクトローカルから始める。

### 品質チェックリスト（公開前）

- [ ] フォルダ名が kebab-case
- [ ] SKILL.md が存在（正確なスペル、大文字小文字区別）
- [ ] YAML フロントマターに `---` デリミタ
- [ ] `name` フィールド: kebab-case、スペースなし、大文字なし
- [ ] `description` に「何を」「いつ」「使わない場面」を含む
- [ ] フロントマターに XML タグ (`< >`) なし
- [ ] 指示が明確かつ実行可能
- [ ] エラーハンドリングを含む
- [ ] 例を提供
- [ ] references を明確にリンク
- [ ] `allowed-tools` で必要最小限のツールに制限
- [ ] テスト済み: 関連クエリでトリガーされ、無関係なクエリではトリガーされない
- [ ] SKILL.md 本文が 5,000 語以内

### パフォーマンスガイドライン

- 20-50 以上のスキルが同時に有効な場合は評価が必要
- 詳細なドキュメントは `references/` に移動（プログレッシブディスクロージャー）
- `allowed-tools` で不要なツールアクセスを制限
- オーバートリガー防止のためネガティブトリガーを追加

## コントリビューション

1. このリポジトリを Fork
2. 上記の Anthropic ベストプラクティスに従ってスキルを追加・修正
3. PR 提出前に品質チェックリストを実行
4. 機密情報（API キー、プロジェクト固有 URL、チーム名）が含まれていないことを確認

## ライセンス

[MIT](LICENSE)
