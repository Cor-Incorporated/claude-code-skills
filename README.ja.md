# Claude Code Skills

[Claude Code](https://claude.com/claude-code)（Anthropic 公式 CLI）のためのスキル・ルール・フック集です。

27 のカスタムスキル、37 の hook スクリプト、5 つのルールセットを含む、本番環境レベルの Claude Code 設定を提供します。

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
├── skills/           # 27 カスタムスキル定義 (SKILL.md + scripts + references)
├── rules/            # 5 グローバルルール (コーディング規約, Git, 品質, テスト, 委任)
├── hooks/            # 37 hook スクリプト (品質ゲート, 安全ガード, ワークフロー強制)
├── scripts/          # 5 ユーティリティ (Codex 連携, PR レビュー, コンテキスト監視)
├── setup.sh          # ワンコマンドインストール
├── settings.json     # 設定テンプレート (パス等サニタイズ済み)
├── README.md         # 英語版 README
└── README.ja.md      # 日本語版 README (本ファイル)
```

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
  code-reviewer, review-loop, e2e, bugfix + 37 hook スクリプト

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

## Hook システム（37 スクリプト）

### 品質ゲート（マージ前）
- `block-merge-without-ci.sh` — CI グリーンなしでマージをブロック
- `block-merge-without-review.sh` — レビュー承認なしでマージをブロック
- `pr-ci-review-gate.sh` — 3 モードゲート (PRE_CREATE / POST_PUSH / STOP)
- `pr-merge-claude-review-gate.sh` — Claude レビュー LGTM 必須
- `pr-guard.sh` — ベースブランチ、Issue 参照、コンフリクトチェック

### 安全ガード
- `protect-branches.sh` — 保護ブランチの削除防止
- `block-manual-merge-ops.sh` — cherry-pick/merge/rebase をブロック（Codex に委任）
- `git-push-guard.sh` — プッシュ安全チェック
- `git-commit-guard.sh` — コミットメッセージとスコープ検証
- `block-version-downgrade.sh` — 依存パッケージのダウングレード防止
- `audit-docker-build-args.sh` — Docker build args の http:// チェック

### コンテキスト予算管理
- `context-budget-read-gate.sh` — 3+ ソースファイル読み込みで警告/ブロック
- `context-budget-write-gate.sh` — テスト/ドキュメント作成を検出し Codex 委任提案
- `context-budget-edit-write-gate.sh` — 多数ファイル読み込み後の編集をブロック
- `context-budget-agent-gate.sh` — エージェント生成数を監視
- `context-budget-reset.sh` — セッション開始時にカウンターリセット

### ワークフロー強制
- `enforce-git-freshness.sh` — リモートより遅れている場合に編集をブロック
- `enforce-factcheck-before-edit.sh` — インフラ変更前にファクトチェック必須
- `enforce-factcheck-before-user-request.sh` — 手動操作依頼前にファクトチェック必須
- `enforce-architecture-layers.sh` — domain/core レイヤー変更を検証
- `enforce-domain-naming.sh` — DDD 命名規則の強制
- `enforce-endpoint-dataflow.sh` — API 変更時のフルデータフロー検証
- `enforce-seed-data-verification.sh` — シードデータの参照ドキュメント照合
- `enforce-issue-close-verification.sh` — Issue クローズ前に受入基準チェック
- `enforce-review-reading.sh` — マージ前に全レビューコメント読了
- `enforce-memory-update-on-commit.sh` — コミット後の MEMORY.md 更新チェック
- `enforce-doc-update-scope.sh` — ドキュメント更新スコープの検証

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

MIT
