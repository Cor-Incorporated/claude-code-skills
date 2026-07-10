# Claude Code Skills

[Claude Code](https://claude.com/claude-code)（Anthropic 公式 CLI）のためのスキル・ルール・フック集です。

27 のカスタムスキル、17 の hook スクリプト（ブロッキング 4 + advisory/infra 13）、6 つのルールセット、6 つのユーティリティスクリプトを含む、本番環境レベルの Claude Code 設定を提供します。[ADR-006](docs/adr/006-minimal-safety-net.md) 以降、hook セットは意図的に最小化されています — ハードブロックは破壊的/不可逆操作のみに限定し、マージ安全性は GitHub branch protection + PR レビューに委譲しています。

[English](README.md) | **日本語**

## クイックスタート

```bash
git clone https://github.com/terisuke/claude-code-skills.git
cd claude-code-skills
chmod +x setup.sh
./setup.sh
```

インストール後、Claude Code を再起動してください。


## API プロバイダ（Claude 正規サブスク ↔ z.ai）

Claude Code はプロセスごとに API ゲートウェイを1つしか使えません。`scripts/claude-provider.sh` で **正規サブスクリプション**（デフォルト・サブエージェント/WebSearch 向け）と **z.ai GLM** を切り替えます。

```bash
bash ~/.claude/scripts/claude-provider.sh status
bash ~/.claude/scripts/claude-provider.sh anthropic   # デフォルト
bash ~/.claude/scripts/claude-provider.sh zai
```

詳細: [docs/runbooks/provider-switching.md](docs/runbooks/provider-switching.md)

## リポジトリ構成

```
claude-code-skills/
├── skills/           # 27 カスタムスキル定義 (SKILL.md + scripts + references)
├── rules/            # 6 グローバルルール (コーディング規約, Git, 品質, テスト, 委任, hookデプロイ)
├── hooks/            # 17 hook スクリプト (ブロッキング 4 + advisory/infra 13); hooks/_unused/ に廃止済み56本 (ADR-006)
├── scripts/          # 6 ユーティリティ (Codex 連携, プロバイダ切替, コンテキスト監視); scripts/_unused/ に廃止済みレビューパイプラインヘルパー
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
| [006](docs/adr/006-minimal-safety-net.md) | Minimal Safety Net — Hook Reduction | Accepted |

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
  code-reviewer, review-loop, e2e, bugfix + 17 hook スクリプト

Reflect (gstack)
  /retro
```

## スキル一覧

### 開発ワークフロー
| スキル | 機能 | トリガー |
|-------|------|---------|
| `code-reviewer` | OWASP セキュリティチェック付き PR レビュー | "review this PR", "code review" |
| `codex-review` | Codex CLI セカンドオピニオンレビュー（`codex exec` 並列エキスパート） | "Codex レビュー", "セカンドオピニオン" |
| `classify-review` | AI による PR レビュー severity 再分類（偽陽性フィルター） | /classify-review [PR番号] |
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
| **A: レビュー** | コードレビュー、セカンドオピニオン（並列エキスパート） | `codex exec --sandbox read-only` / `codex-review` スキル |
| **B: ハンドオーバー** | 大規模実装（ユーザー判断が必要） | ハンドオーバードキュメント作成 → ユーザーが Codex に渡す |
| **C: 並列実行** | 独立タスクを分離 worktree で実行 | `codex-parallel.sh` または `codex-orchestrate.sh` |

### Codex 委任（手動、hook 非強制）

[ADR-006](docs/adr/006-minimal-safety-net.md) 以降、Codex CLI の使用とコンテキスト予算管理は hook で**強制されません** — 従来の `context-budget-*-gate.sh` 群と同時1タスク制限の `codex-task-gate.sh`/`codex-task-release.sh` は廃止されました。経路選択（Agent Team / Codex / 自力実行）は `rules/delegation.md` を指針とするエージェントの判断に委ねられます。`codex-parallel.sh` / `codex-orchestrate.sh` は任意ユーティリティとして引き続き利用可能で、ローカルでの同時実行数制限はありません。

### ユーティリティスクリプト

| スクリプト | 用途 |
|-----------|------|
| `codex-parallel.sh` | 単一タスク Codex 実行（sandbox 自動選択） |
| `codex-orchestrate.sh` | マルチタスク並列実行（JSON/CSV 入力、worktree 分離） |
| `claude-provider.sh` | API ゲートウェイを Anthropic サブスクと z.ai 間で切替 |
| `sanitize-local-permissions.sh` | ローカル設定ファイルの不要な `permissions` ブロックを除去 |
| `delivery_score.py` | 定量的デリバリー品質スコアリング（hookカバレッジ、CI、レビュー） |
| `context-monitor.py` | コンテキストウィンドウ使用量とトークン消費の監視 |

`check-pr-reviews.sh`、`classify-review-state.sh`、`review-comment-set-hash.sh`、`review-evidence-status.sh`、`verify-pr-review.sh` は、それらが支えていたレビューパイプライン hook と共に `scripts/_unused/` へ廃止されました（ADR-006）。

## マージ安全性（GitHub 側、ローカル hook ではない）

ADR-006 以前は `pr-ci-review-gate.sh` + `gate-modes/` によるマルチゲートパイプラインが `gh pr create`/`gh pr merge` をローカルでハードブロックしていました。このパイプラインは廃止されました。マージ安全性は現在、**GitHub branch protection**（required status checks、required reviews、force-push禁止）を `main`/`develop` に設定することと、通常の PR レビューワークフロー（`code-reviewer` スキル、任意で Codex CLI セカンドオピニオン `codex-review`）の責務です。GitHub 上で branch protection が無効・誤設定の場合、ローカルのバックストップは存在しません — 詳細は [ADR-006 の Consequences](docs/adr/006-minimal-safety-net.md#consequences) を参照してください。


## 設計哲学

本リポジトリは3つの基礎原則に基づいています。

### 1. Harness Engineering Best Practices (2026)

[ベストプラクティス記事](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/)に基づくアーキテクチャ:

| 原則 | 実装 | カバレッジ |
|------|------|-----------|
| 決定論的ツールを最小限に適用 | 17 hook スクリプト（ブロッキング4 + advisory13） | ADR-006 |
| フィードバック速度階層 | PostToolUse(ms) > pre-commit > CI(min) > レビュー(hr) | ADR-003 |
| ポインタベースドキュメント | ルール各50行以内（合計122行）、ADR/hookへポインタ | ADR-002 |
| 計画-実行分離 | Plans.md + plan mode + planner エージェント | TaskCreate/Update |
| Git = セッション間ブリッジ | `auto-commit-worktree-changes.sh` + メモリファイル | PostToolUse |
| Claude Code + Codex ハイブリッド | 60/40 分担、委任は現在 hook 強制ではなくエージェント判断 | ADR-004, ADR-006 |

ADR-006 以降、本リポジトリは元記事の「LLMプロンプトより決定論的ツールを徹底適用」という指針の一部を、より小さく高シグナルな hook セットのために意図的にトレードオフしています。偽陽性コストの根拠は
[docs/adr/006-minimal-safety-net.md](docs/adr/006-minimal-safety-net.md) を参照。

### 2. Epic #130:「実装 ≠ 動作」

11/18 のhook (61%) が「実装済み」だが実際には発火しなかった事故から生まれた運用原則:

> **「コードが存在する」と「システムが動作する」は別の検証ステップ。コードレビューだけでは運用の正しさを保証できない。**

以下で強制:
- **4段階検証**: コード存在 → 構文OK → settings.json登録 → 実際に発火
- **`delivery_score.py`**: 定量品質スコア（hookカバレッジ、CI合格率、レビュー遵守率）
- **`enforce-hook-deploy-integrity.sh`**: ソース ↔ デプロイ ↔ 登録の整合性チェック（auto-sync + orphan 検出）
- **CI/CD**: shellcheck + JSON validation + syntax checking（全PR）

**Epic #130 前**: hookゲート動作率 39% (7/18) → **Epic #130 後・ADR-006 前**: 98%+ (59/59 hooks 登録 + デプロイ済み) → **ADR-006 後（現在）**: 17/17 hooks 登録 + デプロイ済み — 生き残ったセットは drift ではなく設計により小さい。デプロイ整合性検証は引き続き全 hook に適用。

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

## Hook システム（17 スクリプト）

hook ごとの詳細（イベント、matcher、用途）は [hooks/README.md](hooks/README.md) を参照。
72 登録コマンドから 17 への削減理由は [ADR-006](docs/adr/006-minimal-safety-net.md) を参照。

### ブロッキング（4 — PreToolUse ハードブロック、exit 2）
- `git-push-guard.sh` — 保護ブランチへの force-push / 直接 push をブロック
- `protect-branches.sh` — 保護ブランチの削除防止
- `block-local-hooks-write.sh` — settings.local.json によるグローバル hook 上書きを防止
- `validate-no-local-hooks.sh` — SessionStart で既存の上書きがないか検証

### advisory / infra（13 — 情報提供のみ、ブロックしない）
- `auto-init-permissions.sh` — no-op。パーミッションは settings.json が正
- `auto-update-plugins.sh` — サードパーティプラグイン更新（24h クールダウン）
- `validate-provider-env.sh` — セッション開始時に API プロバイダルーティング（Anthropic/z.ai）を確認
- `enforce-branch-workflow.sh` — develop ブランチ自動作成、main/develop 上での警告
- `enforce-hook-deploy-integrity.sh` — hook のインストール・登録を検証（auto-sync + orphan 検出）
- `enforce-hook-deploy-after-merge.sh` — hooks/ を変更した PR マージ後に hook を自動デプロイ
- `verify-agent-output.sh` — エージェントの phantom completion を検出（#173）
- `auto-commit-worktree-changes.sh` — マージ後に worktree エージェント変更を自動コミット（#220）
- `post-deploy-verify.sh` — デプロイコマンド後の検証チェックリスト注入
- `post-lint-format.sh` — 編集後の Quality Loop：自動修正 → 残存チェック（ADR-001/003）
- `notify-agent-failure.sh` — エージェント失敗コンテキストの伝播（PostToolUseFailure）
- `tool-failure-recovery.sh` — ツール失敗時のエラー回復ガイダンス（PostToolUseFailure）
- `pre-compact-context-save.sh` — コンパクション前に重要コンテキストを保存（PreCompact）

以前アクティブだった 56 スクリプト（レビュー/CI マージゲート一式、ファクトチェック群、コンテキスト予算群、Codex 単一呼び出しゲート、state-file 改ざん防止群など）と、旧 `hooks/gate-modes/` ディスパッチャ一式は `hooks/_unused/` へ廃止済みです。廃止リストと理由は
[hooks/README.md#_unused-archive](hooks/README.md#_unused-archive) と ADR-006 を参照。

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
