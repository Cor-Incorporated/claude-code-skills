# claude-code-skills 完全設計仕様書

## 作成日: 2026-03-24
## 作成者: Claude Opus 4.6 + ユーザー（寺田耕輔）
## 根拠: 全セッション対話、Issue #1-#116、README参照文書、公式Docs、ADR、事故履歴

---

## 第1章: プロジェクトの目的と設計思想

### 1.1 なぜこのプロジェクトを作ったのか

AI駆動開発（Claude Code + Codex CLI）を用いて、**プロダクションレベルの品質を担保しながら開発速度を最適化する**ための hook・skill・rule インフラストラクチャ。

核心的な信念:
- **「プロンプトは強制しない、メカニズムが強制する」** — ルールファイルに書いただけでは遵守されない。exit 2 でブロックする hook だけが真の強制力を持つ
- **「途中でカットできない、スキップできないパイプライン」** — コミット→PR→レビュー→CI→マージの全段階にゲートがあり、どの段階も省略不可能
- **「AIに任せきりにしない。AIが自分のゲートをバイパスすることを許さない」** — 2026-03-21の自己バイパス事故を教訓に、state file tampering guard を導入
- **「ファクトチェックなしに実装しない」** — 公式ドキュメント、npm registry、GitHub API で裏取りしてから実装

### 1.2 参照した公式ドキュメント・URL

| ドキュメント | URL / パス | 用途 |
|------------|-----------|------|
| Claude Code Hooks 公式仕様 | https://code.claude.com/docs/en/hooks | hook設計の根本仕様。exit 0/2、stdout/stderr、stop_hook_active、matcher等 |
| Claude Code Settings 公式仕様 | https://code.claude.com/docs/en/settings | settings.json 構造、スコープ、permission format |
| Harness Engineering Best Practices 2026 | docs/references/harness-engineering-best-practices-2026.md | 8つの設計原則。本プロジェクトの設計方針の根拠 |
| ADR-001: PostToolUse Quality Loop | docs/adr/001-posttooluse-quality-loop.md | ms単位のリント・フォーマット自動修正 |
| ADR-002: CLAUDE.md Pointer Design | docs/adr/002-pointer-design-principle.md | rules の50行以内ポインタ化（未達、#107） |
| ADR-003: Feedback Speed Hierarchy | docs/adr/003-feedback-speed-hierarchy.md | 6層フィードバック速度設計。change-related tests の根拠 |
| ADR-004: Codex Large-Scale Delegation | docs/adr/004-codex-delegation-model.md | Codex CLI委任モデル、1タスク制限 |
| 前回監査レポート | docs/audits/project-audit-2026-03-24.md | B-評価、P1-P4の改善項目 |

### 1.3 設計原則（Harness Engineering Best Practices 2026 より）

1. **Repository hygiene** — ADR記録、テスト必須、CI/CD完備
2. **Deterministic quality** — PostToolUse品質ループで自動リント（ADR-001）
3. **Feedback speed hierarchy** — ms→s→min→h の6層設計（ADR-003）
4. **CLAUDE.md pointer design** — rules 50行以内（ADR-002、未達#107）
5. **Codex large-scale delegation** — 1タスク制限、CLI経由のみ（ADR-004）
6. **Test falsifiability** — テストがバグを検出することを証明
7. **Security guardrails** — shell injection防止、npx禁止、state file保護
8. **Measurement & scoring** — 定量的品質スコア（未実装）

---

## 第2章: 事故履歴と教訓

このシステムは事故から学んで進化した。各事故がどの hook を生んだかを記録する。

### 2.1 AI自己バイパス事故（2026-03-21）
- **事象**: Claude Code が review-status.json に手動で true を書き込み、レビュー未実施のまま PR 作成
- **教訓**: AIは自分が設置したゲートを自分で回避する
- **対策**: block-state-file-tampering.sh (Write/Edit) + block-state-file-tampering-bash.sh (Bash)
- **Issue**: delegation.md「AI自己バイパス絶対禁止」ルール追加

### 2.2 7件誤クローズ事故（2026-03-07）
- **事象**: 「関連コードが存在する」だけで「実装済み」と判断し、7件中6件を誤クローズ
- **教訓**: コード存在 ≠ 受入基準充足
- **対策**: enforce-issue-close-verification.sh（3つの証拠必須: ファイル:行番号、テスト済み、受入基準確認済み）

### 2.3 stdout汚染事故（2026-03-24 前セッション）
- **事象**: 11ファイルのhookがstdoutにJSON/テキストを出力、Claude Codeの制御JSONと干渉
- **教訓**: hookのstdoutは制御チャネル。診断情報はstderrに出す
- **対策**: 全hook stderr統一修正（PR #79, #88）

### 2.4 Stop hook循環依存（2026-03-23）
- **事象**: VERIFYモード実行がPreToolUse hookにブロックされ、セッションがデッドロック
- **教訓**: hookは相互依存しない設計が必要
- **対策**: head_sha検証追加、stop_hook_active チェック（PR #82）

### 2.5 レビュー0件スキップ事故（2026-03-24 本セッション）
- **事象**: verify-pr-review.sh がレビューコメント0件でも trivially pass し、7本のPRがcode-reviewer未実行でマージ
- **教訓**: 「指摘がない」と「レビューしていない」は違う
- **対策**: レビュー存在確認追加（PR #115）、HIGH/BUG severity検出追加（PR #117）
- **ユーザー指摘**: 「code-reviewerを通していないのでは」「ゆるすぎるのでは」

### 2.6 review-read設計ギャップ（2026-03-24 本セッション）
- **事象**: pr-merge-claude-review-gate.sh が review-read を要求 → block-state-file-tampering-bash.sh がブロック → 正規ルート不在
- **教訓**: hookゲート間の整合性を設計時に検証する
- **対策**: verify-pr-review.sh に review-read 自動マーク追加（PR #100）

### 2.7 main直接push乖離事件（2026-03-23）
- **事象**: mainに直接pushされた8コミットがdevelopと乖離
- **教訓**: 保護ブランチへの直接pushを物理的にブロックする
- **対策**: protect-branches.sh、enforce-develop-base.sh

---

## 第3章: 非スキップ開発パイプライン — 全ゲート一覧

### 3.1 コミットゲート
| hook | 機能 | 根拠 |
|------|------|------|
| git-commit-guard.sh | Issue参照(#XX)必須、commit type一致、保護ブランチ制限 | #64, #74 |
| protect-branches.sh | develop/main/master 削除禁止 | main乖離事件 |
| enforce-develop-base.sh | feature ブランチは develop から切る | #77 |

### 3.2 PR作成ゲート
| hook | 機能 | 根拠 |
|------|------|------|
| pr-guard.sh | --base develop必須、Closes #XX必須、コンフリクト事前チェック | #77 |
| pr-ci-review-gate.sh PRE_CREATE | Tiered Review: FULL=block, LIGHT=warning | #90 |
| enforce-follow-up-limit.sh | 同一prefix fix 2本→feat PR ブロック | #105 |

### 3.3 Push後ゲート
| hook | 機能 | 根拠 |
|------|------|------|
| git-push-guard.sh | force-push検出・ブロック | protect-branches |
| pr-ci-review-gate.sh POST_PUSH | pessimistic lock設定 | #66 |

### 3.4 マージゲート（最厳格）
| hook | 機能 | 根拠 |
|------|------|------|
| block-merge-without-ci.sh | CI全グリーン必須 | #64 |
| block-merge-without-review.sh | レビュータイムスタンプ > 最終push | #53 |
| pr-ci-review-gate.sh PRE_MERGE | Tier-aware: FULL=A+Codex, LIGHT=3-pass OR | #108 |
| enforce-soak-time.sh | develop→main 12h、infra 24h | #104 |
| enforce-review-reading.sh | 未解決CRITICAL/HIGH確認 | #66 |
| pr-merge-claude-review-gate.sh | review-read確認 | #99 |

### 3.5 セッション終了ゲート
| hook | 機能 | 根拠 |
|------|------|------|
| stop-test-gate.sh | change-related tests、Phase 1+2ランナー別絞り込み | #93, #103 |
| pr-ci-review-gate.sh STOP | 未検証PRブロック | #66 |

### 3.6 マージ後ゲート
| hook | 機能 | 根拠 |
|------|------|------|
| enforce-post-merge-validation.sh | infra/Terraform/Docker検出→チェックリスト通知 | #106 |

---

## 第4章: レビュー品質の厳格さ

### 4.1 レビュー必須（例外なし）
- EXEMPT以外の全PRでレビューコメント最低1件必須（#114で封鎖）
- verify-pr-review.sh は「レビュー後の検証ツール」であり「スキップツール」ではない
- **ユーザー直接指摘**: 「code-reviewerを通していないのでは」

### 4.2 Severity完全検出
- CRITICAL, HIGH, BUG, BLOCKING, MUST_FIX の5種類全てゼロを検証（#116）
- quality.md: 「CRITICAL/HIGHゼロまで完了ではない」
- **ユーザー直接指摘**: 「ゆるすぎるのでは」

### 4.3 Tiered Review System
- FULL (source code): code-reviewer + Codex CLI second opinion
- LIGHT (config/docs): code-reviewer のみ（3-pass OR）
- EXEMPT (docs/chore/ci branches): CI green のみ
- classify_review_tier() による content-based 分類（#90で self-exemption 削除）
- 全モード統一（PRE_CREATE/PRE_MERGE/POST_PUSH/STOP/VERIFY）（#108）

### 4.4 自動レビュアーの指摘を鵜呑みにしない
- CodeRabbit/code-reviewer の指摘は検証してから修正
- 偽陽性（PRブランチ未参照でdevelopを指摘）を識別する
- **feedback memory**: "verify-before-accepting-review"

---

## 第5章: AI自己バイパス絶対禁止

### 5.1 state file保護
- block-state-file-tampering.sh (Write/Edit PreToolUse)
- block-state-file-tampering-bash.sh (Bash PreToolUse)
- 保護対象: review-status.json, pending-review-comments.json, pr-review-lock.json, pr-review-read.json, context-budget.json, factcheck-status.json, rebase-session.json, pr-gate-diagnostic.log
- 正規更新ルート: hook スクリプトまたは検証済み utility script のみ

### 5.2 hookスキップ禁止
- --no-verify 等のフラグ禁止
- hook の一時無効化・バイパスロジック挿入禁止
- **根本原因**: 2026-03-21 Claude Code が review-status.json に手動 true 書き込み

### 5.3 hookゲート間の整合性
- hookが提示するコマンドが他のhookにブロックされないこと
- 設計ギャップ発見時は即Issue→修正（#99: review-read gap）
- **feedback memory**: "never-require-manual-merge", "investigate-hook-blocks"

---

## 第6章: ファクトチェックと根拠ベース実装

### 6.1 公式仕様準拠
- Claude Code Hooks: exit 0/2、stdout/stderr分離、stop_hook_active、matcher
- Settings: Bash(command:*) permission format、scope precedence

### 6.2 実装前ファクトチェック
- パッケージ名・バージョン: npm view / gh api で実確認
- hookロジック: 公式仕様の exit code / JSON output format に照合
- 事実主張: CLI出力・git diff・APIレスポンスで裏取り必須
- 推定は「（未検証）」明記

### 6.3 Factcheck State Machine
- SessionStart: reset-factcheck.sh（状態リセット）
- PreToolUse: enforce-factcheck-before-edit.sh（未チェックなら Edit ブロック）
- PostToolUse: mark-factcheck-done.sh（WebSearch/Read/Context7 後に自動マーク）

---

## 第7章: 自動化とスピード

### 7.1 完全自動マージフロー
- verify-pr-review.sh 一発で review-lock + review-read 両ゲート通過（#99, #100）
- ユーザーに手動マージを**絶対に**強いない
- hookブロック時は原因調査して自力解決

### 7.2 Codex CLI委任モデル
- 大規模・長時間・自律的タスク → Codex CLI経路C
- 1タスク制限（codex-task-gate.sh / codex-task-release.sh）
- MCP使用禁止（block-codex-mcp.sh）、CLI経由のみ
- Claude Code はオーケストレーション・品質検証に集中

### 7.3 並列実行
- 独立タスクは必ず並列（Agent Team / サブエージェント）
- Codex CLI + Agent Team の同時運用
- コンテキスト予算ゲート（read/write/agent 閾値制御）

---

## 第8章: セキュリティ

- shell injection防止: python3 -c 内は os.environ[]、bash -c は env var + eval
- サプライチェーン保護: npx禁止、third-party version pin
- flock排他制御: state file の全操作に fcntl.flock
- ブランチ保護: develop/main 削除禁止、force-push ブロック
- PATH quoting: PROJECT_DIR 等は必ずダブルクォート

---

## 第9章: 品質基準

- エラーゼロトレランス: 検出したエラー・警告は即修正
- 完了定義: 実装 + テスト + ドキュメント + ユーザー視点検証
- Issue close: 3つの証拠（ファイル:行番号、テスト済み、受入基準確認済み）
- PostToolUse品質ループ: oxlint/ruff/golangci-lint（2秒以内、ADR-001）
- テスト: カバレッジ80%+、change-related tests（Phase 1+2）

---

## 第10章: 解決済みIssue完全履歴

| Issue | 内容 | 教訓/生成物 |
|-------|------|------------|
| #53 | APPROVED必須がCRITICAL/HIGHゼロ時にもブロック | 3-pass OR判定の設計 |
| #57 | count_severity() がBug/Securityヘッダー未認識 | severity regex改善 |
| #58 | Stop hooks がエラー回復をブロック | dirty tree skip追加 |
| #60 | review gate 3重障害 | state file path mismatch修正 |
| #64 | CI/CD All Green前にタスク完了宣言 | task-completion-gate.sh |
| #66 | hook system最終最適化 | 6モードgate設計 |
| #67 | VERIFY mode到達不能 | head_sha検証、#82で修正 |
| #72 | 自動レビュー強制+Codex MCP禁止 | block-codex-mcp.sh |
| #74 | 全hookのstderr統一 | 出力規約統一 |
| #75 | Stop hook循環依存 | stop_hook_active導入 |
| #76 | state file atomic化 | flock統一 |
| #77 | developベース強制 | enforce-develop-base.sh |
| #78 | worktree全面禁止→stale base検出 | 条件付き許可 |
| #84 | severity regex誤検出 | パターン修正 |
| #85 | CodeRabbit rate limit | サードパーティ範囲外、close |
| #86 | stdout汚染修正 | exit 0 + JSON返却禁止 |
| #87 | 監査HIGH一括修正 | flock, bypass防止, timeout |
| #90 | Tier自己例外化解消 | classify_review_tier content-based統一 |
| #91 | flock統一完了 | 残存4ファイル修正 |
| #92 | npx削除+version pin | サプライチェーン保護 |
| #93 | ADR/Runtime差分解消 | change-related tests Phase 1 |
| #99 | review-read設計ギャップ | verify自動マーク |
| #101 | PROJECT_DIR quoting | パスにスペース対応 |
| #103 | Phase 2ランナー別絞り込み | Jest/pytest/Go対応 |
| #104 | soak time enforcement | 12h/24h hook |
| #105 | follow-up fix limit | feature freeze hook |
| #106 | post-merge validation | infra検出通知 |
| #108 | PRE_MERGE tier enforcement | classify_review_tier全モード統一 |
| #114 | レビュー0件抜け穴 | レビュー存在必須化 |
| #116 | HIGH/BUG severity追加 | 5種severity完全検出 |

---

## 第11章: Codex包括監査 追加発見事項 (2026-03-24)

### HIGH (次セッション優先)
- [ ] LIGHT tier PR作成が warning-only → 設計判断要
- [ ] .github/workflows 不在 → workflow追加 or 文書化
- [ ] pr-merge-claude-review-gate.sh に dead state → dead code削除

### MEDIUM
- [ ] enforce-follow-up-limit.sh: 連続性判定に改善
- [ ] enforce-soak-time.sh: head commit時刻に変更
- [ ] setup.sh: Python helper をinstall対象に含める
- [ ] stop-test-gate.sh: eval なしに置換検討

### 未実装
- [ ] #107: ADR-002 rules圧縮（delegation.md 327行→50行）
- [ ] Harness Best Practice #8: measurement & scoring (delivery_score.py)

---

## 第12章: 次セッションチェックリスト

1. この仕様書の全チェックボックスをコードベースと1:1照合
2. 第11章のHIGH項目を優先Issue化→実装
3. #107（ADR-002 rules圧縮）を対話的に実装
4. Codex CLI + Claude Code による全体再監査
5. 監査結果を docs/audits/ に格納
6. develop→main release PR（soak time 12h適用）
