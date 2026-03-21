# エージェント & 並列実行 & Codex委任

## 運用方針（2026-03-10 最適化）
- **Claude Code 60%**: 設計・並列実装・統括・ユーザー対話。エージェントチームによる有機的協調が強み
- **Codex CLI 40%**: 直列実装・運用・品質監査。worktree分離・長時間自律実行・GitHub/Supabase統合が強み
- **PM機能**: Claude Code自身がPMを兼任（ソロ運用）。Plans.mdでタスク管理

## Claude Code の強み（Codexに委任しない）
- エージェントチームによる有機的並列実装（相互参照・動的協調）
- サブエージェント間の対話的協調（Agent Aの結果をAgent Bが即座に参照）
- コンテキスト共有型の創造的・設計的実装
- リアルタイムの判断ループ（方針変更に即応答）
- セキュリティ判断・アーキテクチャ設計

## Codex CLI の強み（Claude Codeから委任する）
- 長時間直列タスク（コンパクティング回避）
- worktreeによる完全分離実行（メインの作業を邪魔しない）
- GitHub統合（PR作成・Issue管理・checks確認・コメント追加）
- Supabase統合（SQL実行・migration・Edge Function・型生成）
- 品質監査の定量実行（repo_delivery_audit.py）
- delivery統制（merge gate・soak time判定）

## 核心ルール
- 独立タスクは必ず並列実行。順次は依存関係がある場合のみ
- 2タスク以上の独立実装 → エージェントチーム必須（レビューエージェント含む）
- **長時間直列タスク → Codex CLIに委任**（コンパクティング回避）
- コンパクティング後にシングルに戻るの禁止。TaskListで状態確認して再開
- **Codex CLI 経路Cに3タスク以上が集中する場合 → Agent Team (worktree isolation) に分散**

## Agent Team vs Codex CLI 判断基準（2026-03-21追加）

Codex CLI 経路Cへの担当集中を防ぐため、以下の基準で Agent Team を優先する:

| 条件 | 担当 | 理由 |
|------|------|------|
| 1ファイル変更、lint/build不要 | Agent Team (worktree) | 軽量タスク、Codex起動オーバーヘッド不要 |
| frontend OR backend 片方のみ | Agent Team (worktree) | コンフリクトリスク低い |
| ドキュメント作成 | Agent Team (technical-writer) | コード変更なし |
| frontend+backend 跨ぎ + テスト作成 | Codex CLI 経路C | 複雑な依存関係 |
| 3ファイル超の変更 + CI検証必要 | Codex CLI 経路C | 長時間自律実行が有利 |
| GitHub/Supabase API操作を含む | Codex CLI | 統合ツールが必要 |

### Agent Team worktree ルール
- `isolation: "worktree"` で起動 → git worktreeで完全分離
- 変更完了後、メイン agent が差分を検証してからブランチにマージ
- **同じファイルを触るタスクは絶対に別 worktree で並列起動しない**
- worktree agent は**PRを作成しない** — メイン agent が統合してPR作成

### 並列上限の厳守
- Codex CLI: **最大2並列**（worktree分離。3並列はコンフリクトリスクが高い）
- Agent Team: 最大5並列（worktree + in-process混在）
- **合計7を超えない** — それ以上はキューイングまたは優先度判定
- Codex CLI 2並列を超えるタスク → Agent Team (worktree) にオーバーフロー

## コンテキスト予算ゲート（2026-03-10追加・必須）
タスク着手前に以下のチェックを実施し、自力実行 vs Codex委任を判定する。
判定をスキップして自力実行した場合、ルール違反とみなす。

### 判定基準
| 指標 | 閾値 | 超過時のアクション |
|------|------|-------------------|
| 読み込みファイル数 | 3ファイル超 | Codex CLI経路Cに委任 |
| 新規ファイル作成 | テスト/ドキュメント | Codex CLI経路Cに委任 |
| 予想所要ターン数 | 5ターン超 | Codex CLI経路Cに委任 |

### テスト作成は原則Codex委任
以下のテスト作成タスクは**Codex CLI経路C**がデフォルト:
- スモークテスト / E2Eテスト（既存パターンの踏襲）
- ユニットテストの穴埋め（カバレッジ向上）
- Live APIテスト（DB検証含む）

**例外**（Claude Codeが自力で行ってよい場合）:
- テスト設計にリアルタイムの対話的判断が必要
- テストと実装が同時進行中（TDDの Red-Green サイクル内）
- 1ファイル・10行未満の軽微なテスト追加
- **Live APIテスト実行**: Codex sandboxはlocalhost接続を制限するため、
  実行中のローカルサーバーやDBに対するテスト実行はClaude Codeが担当する。
  ただしテストスクリプトの**作成**はCodexに委任し、**実行のみ**Claude Codeが行う。

### Claude Codeの役割限定
コンテキスト予算ゲートに該当するタスクでは、Claude Codeは以下のみ行う:
1. **仕様整理**: 検証項目を箇条書き（3-5行）にまとめる
2. **委任指示作成**: Codex向けプロンプトに必要最小限のコンテキストを記載
3. **結果受領・判断**: Codexの出力を受け取り、ユーザーに報告・判断を仰ぐ

ソースコードの全文読み込みや新規ファイル作成を自力で行わない。

### Hook enforcement（2026-03-11追加・自動）
コンテキスト予算ゲートは以下のPreToolUse hookで**機械的に強制**される:
| Hook | トリガー | 動作 |
|------|---------|------|
| `context-budget-read-gate.sh` | Read tool使用時 | 3+ファイルで警告、6+で強い警告 |
| `context-budget-write-gate.sh` | Write tool使用時 | テスト/ドキュメント作成検出→Codex委任提案 |
| `context-budget-agent-gate.sh` | Agent tool使用時 | 3+エージェントでCodex orchestration推奨 |
| `context-budget-reset.sh` | SessionStart | セッション開始時にカウンターリセット |

**状態ファイル**: `~/.claude/state/context-budget.json`
**除外対象**: `.claude/`配下, `CLAUDE.md`, `MEMORY.md`, `node_modules/`, `package-lock.json`

hookが警告を出した場合、Claude Codeは以下のいずれかを行う:
1. Codex CLI経路Cに委任する（推奨）
2. 例外事由を明示してユーザーに確認する（対話的判断が必要な場合のみ）

## エージェント一覧
planner(計画), architect(設計), tdd-guide(TDD), code-reviewer(レビュー), security-reviewer(セキュリティ), build-error-resolver(ビルド), e2e-runner(E2E), refactor-cleaner(削除), Explore(調査), general-purpose/haiku(軽量)

## 即時使用（指示不要）
複雑な機能→planner / コード作成後→code-reviewer / バグ修正→tdd-guide / ビルド失敗→build-error-resolver

## 並列の上限
サブエージェント5-7同時 / Bash3-4同時 / Codex CLI **2並列** / ファイル読み取り制限なし

## コンテキストウィンドウ管理
- **残り20%**: 新規タスク開始禁止。進行中タスクの完了・コミットに集中
- **残り10%**: 状態をメモリに保存し、ユーザーに継続セッション開始を提案
- **コンパクティングリスクが高い長時間タスク → Codex CLIに事前委任**
- コンパクティング発生時: TaskListで進行中タスクを確認してから再開

---

## Codex委任: 3つの経路

### 経路A: Codex CLI レビュー（旧MCP → CLI移行）
**用途**: コードレビュー、セカンドオピニオン
**コマンド**: `codex exec -C <repo> -o <output> review --base <branch>`
**利点**: タイムアウトなし、JSON出力対応、`--uncommitted`で未コミット変更もレビュー可能
**適用**: レビュー / セカンドオピニオン / 型チェック / 簡易調査
```bash
# Claude Codeから直接呼び出し:
bash ~/.claude/scripts/codex-parallel.sh --review ~/Developer/<repo> --base develop
```

### 経路B: Codex本体へのハンドオーバー（実装委任）
**用途**: 大規模実装タスク（ユーザー判断が必要なもの）
**方法**: ハンドオーバードキュメントを作成 → ユーザーがCodexに渡す

### 経路C: Codex CLI 並列実行（監査2026-03-10追加）
**用途**: 独立した実装タスクの自動並列実行
**コマンド**: `codex exec` + git worktree で分離実行
**利点**: worktreeで完全分離、複数同時実行、Claude Codeのコンテキスト消費なし
**適用**: テスト作成 / ドキュメント更新 / レビューfollow-up fix / リファクタ / CI修正
**補足**: release / infra / migration 系をCodexに委任しても、`git-workflow.md` の soak time と post-merge 検証ルールは必ず適用する
```bash
# 単一タスク (内部でサブエージェント自動活用):
bash ~/.claude/scripts/codex-parallel.sh ~/Developer/<repo> <branch> "プロンプト"

# 複数タスク並列 (worktree分離):
bash ~/.claude/scripts/codex-orchestrate.sh ~/Developer/<repo> tasks.json

# CSV一括 (同種タスクのfan-out、Codex内部サブエージェント活用):
bash ~/.claude/scripts/codex-orchestrate.sh --csv ~/Developer/<repo> tasks.csv "テンプレート"
```

#### Codex sandbox自動選択（2026-03-11追加）
`codex-parallel.sh`はプロンプト内容からsandboxレベルを自動判定する:
| パターン | sandbox | 理由 |
|----------|---------|------|
| docker/chmod/gcloud/terraform | `danger-full-access` | システムレベルアクセス必要 |
| npm install/curl/fetch/gh pr | `workspace-write` | ネットワーク+ファイルアクセス |
| デフォルト | `workspace-write` | 安全な読み書きのみ |

手動オーバーライド: `CODEX_SANDBOX=danger-full-access bash codex-parallel.sh ...`
タスクごとオーバーライド: tasks.jsonに`"sandbox": "danger-full-access"`を追加
`--full-auto`は実行モード指定であり、sandbox値ではない。sandboxに指定できるのは`read-only` / `workspace-write` / `danger-full-access`のみ。

**tasks.json例**:
```json
{
  "tasks": [
    {"branch": "test/user-service", "prompt": "UserServiceのunit testを作成", "paths": ["src/services/user", "tests/unit/user"]},
    {"branch": "docs/api-update", "prompt": "APIドキュメントを更新", "paths": ["docs/api"]},
    {"branch": "fix/review-123", "prompt": "PR #123 レビュー指摘修正", "paths": ["src/features/review"], "sandbox": "danger-full-access"}
  ]
}
```

#### Codex内部サブエージェント活用（2026-03-11追加）
`config.toml`で`[agents]`セクションが有効化済み（max_threads=6, max_depth=2）。
`codex-parallel.sh`のプロンプトに「サブエージェント活用」指示が組み込まれており、
Codexが自動判断でタスクを内部分割し並列実行する。

**並列化の階層**:
```
Claude Code（計画・設計・調査）
  └─ codex-orchestrate.sh（3 worktree並列）
       └─ 各worktree内: Codex exec（最大6サブエージェント並列）
            └─ spawn_agents_on_csv（大量同種タスク時）
```
最大ポテンシャル: 3 worktree × 6 sub-agents = **18並列**
ただしこれは上限値であり、`features.multi_agent = true` が有効なセッションでのみ成立する。multi-agentはexperimentalのため、セッションやstate DBの状況で不安定化する場合がある。

**使い分け**:
| パターン | ツール | 例 |
|----------|--------|-----|
| 異なるタスクを別ブランチで | `codex-orchestrate.sh` (JSON) | テスト+ドキュメント+リファクタ |
| 同じ操作を多数ファイルに | `codex-orchestrate.sh --csv` | 22スキルファイルの一括書き換え |
| 1タスク内の自動分割 | `codex-parallel.sh` (内部spawn) | テスト作成でモジュールごとに分割 |

**CSV fan-out例**:
```csv
file,module,action
src/services/user.ts,UserService,unit testを作成
src/services/payment.ts,PaymentService,unit testを作成
src/services/auth.ts,AuthService,unit testを作成
```
```bash
bash ~/.claude/scripts/codex-orchestrate.sh --csv ~/Developer/repo tasks.csv "{module}の{action}: {file}"
```

#### ハンドオーバードキュメント必須項目
```markdown
# Codex Implementation Request

## タスク概要
（1-2文で何をするか）

## 背景・コンテキスト
（なぜこの変更が必要か、関連するIssue/PR番号）

## 実装要件
- [ ] 具体的な変更内容1
- [ ] 具体的な変更内容2

## 対象ファイル
- `path/to/file.ts` - 変更内容の概要

## 既存パターン・参照コード
（既存の類似実装があれば、ファイルパスとパターンを示す）

## インターフェース / APIシグネチャ
（入出力の型定義、関数シグネチャ）

## 禁止事項
- セキュリティ制約、スタイル制約、変更禁止ファイル

## コミット指示
- ブランチ名: `feat/xxx` or `fix/xxx`
- コミットメッセージ形式: `<type>: <description>`

## 検証方法
（テストコマンド、型チェック等）

## 品質ゲート（監査2026-03-10追加・必須）
- [ ] branch名とcommit typeの一致確認
- [ ] 1 commitに複数意図を混ぜていないこと
- [ ] feat commitにはtest commitを含めること
- [ ] env var追加時はREADME/docsに記載すること
- [ ] follow-up fixの場合: 元PR番号を明記すること
- [ ] infra変更の場合: post-merge検証手順を記載すること
```

### 委任Tier（2026-03-21改訂: Agent Team追加）
| Tier | タスク例 | 担当 |
|------|---------|------|
| **設計・協調** | アーキテクチャ, 相互依存実装, 創造的設計 | Claude Code（エージェントチーム） |
| **並列実装** | 複数機能の同時開発, TDD, 相互レビュー | Claude Code（サブエージェント） |
| **軽量並列** | 1ファイル修正, Dockerfile変更, 設定変更 | **Agent Team（worktree isolation）** |
| **ドキュメント** | docs作成/更新, セットアップガイド, README | **Agent Team（technical-writer）** |
| **レビュー** | コードレビュー, セカンドオピニオン | Codex CLI（経路A）or Agent Team（code-reviewer） |
| **直列実装** | 大量テスト, 全ファイルリファクタ, migration | Codex CLI（経路C・コンパクティング回避） |
| **複合並列** | frontend+backend跨ぎ + テスト作成 | Codex CLI（経路C・worktree並列） |
| **運用** | GitHub PR/Issue, Supabase, 品質監査 | Codex CLI |
| **大規模委任** | ユーザー判断必要な実装 | ハンドオーバー（経路B） |
| **対話・判断** | リアルタイム対話, セキュリティ, 方針変更 | Claude Code（メイン） |

### 委任判断フロー（2026-03-21改訂）
```
タスク受信
├─ 対話・判断が必要? → Claude Code（メイン）
├─ 複数タスクが相互依存? → Claude Code（エージェントチーム）
├─ 創造的・設計的な実装? → Claude Code（planner + architect）
├─ 1-2ファイル変更 + lint不要? → Agent Team（worktree isolation）
├─ ドキュメント作成/更新? → Agent Team（technical-writer）
├─ レビュー? → Agent Team（code-reviewer）+ Codex CLI（経路A）
├─ 長時間直列（コンパクティングリスク）? → Codex CLI（経路C）
├─ frontend+backend跨ぎ + テスト? → Codex CLI（経路C）
├─ Codex CLI 経路Cが既に3並列? → Agent Team（worktree）にオーバーフロー
├─ GitHub/Supabase操作? → Codex CLI
├─ ユーザー判断が必要な大規模実装? → ハンドオーバー（経路B）
└─ 調査が必要? → Explore エージェント
```

## レビューパイプライン（PR前必須）
1. code-reviewerエージェント
2. Codex CLIセカンドオピニオン: `codex exec -C <repo> -o review.md review --base <branch>`
3. 全指摘修正（指摘が独立なら経路Cで並列修正可）
4. PR作成
