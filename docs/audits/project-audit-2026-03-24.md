# Project Comprehensive Audit Report — 2026-03-24

## Overview

Claude Code Skills プロジェクト全体を以下の観点で包括監査した結果レポート。

- **監査実施者**: code-reviewer Agent + Codex CLI (gpt-5.4) セカンドオピニオン
- **監査対象**: develop ブランチ (commit `f0d94bd`)
- **監査基準**: Claude Code 公式仕様、README 参照ドキュメント、ADR、DDD 原則
- **公式仕様**: https://code.claude.com/docs/en/hooks

---

## Total Score: B-

| # | Evaluation Axis | Grade | Summary |
|---|----------------|-------|---------|
| 1 | Claude Code 公式仕様準拠 | **A-** | イベント配線・stop_hook_active・matcher 全て整合。stdout 汚染は本セッションで修正済み |
| 2 | 参照ドキュメント・ベストプラクティス | **C+** | skills 構造は良いが、ADR-002 圧縮未達、third-party 未固定 |
| 3 | DDD/プロダクションワークフロー | **B-** | ルール群は強いが、LIGHT tier 自己例外化で設計厳格さが崩れる |
| 4 | AI 駆動開発の自動化 | **B** | Codex 委任・anti-bypass・review pipeline は成熟。一部矛盾あり |
| 5 | セキュリティ・品質 | **C** | 防御 hook は多いが、npx 許可・非原子的更新・shell interpolation 残存 |

---

## Detailed Findings

### 1. Claude Code 公式仕様準拠 (A-)

**Strengths:**
- 全 52 hook のイベント配線が公式仕様と整合
- `PostToolUseFailure`, `TaskCompleted` 等の新イベントも正しく活用
- Stop hook の `stop_hook_active` 無限ループ防止を全箇所で実装
- matcher は全て有効な正規表現（`Edit|Write`, `mcp__codex__.*` 等）
- matcher 非対応イベント（`Stop`, `UserPromptSubmit` 等）に matcher を設定していない

**Issues fixed in this session:**
- CRITICAL: stdout 汚染 11 ファイル修正 (PR #88)
- CRITICAL: STOP mode exit 0 + JSON block → exit 2 + stderr (PR #88)
- HIGH: stderr 出力統一 3 ファイル (PR #79)

**Remaining:**
- None critical

### 2. 参照ドキュメント・ベストプラクティス (C+)

**Strengths:**
- skills 構造が Anthropic 公式ベストプラクティスに準拠（SKILL.md + scripts/ + references/）
- ADR 4 件で設計判断を記録

**Weaknesses:**
- ADR-002 の圧縮方針（CLAUDE.md をポインター化）が rules/ の肥大化で一部未達
- third-party 統合（gstack, ui-ux-pro-max）が HEAD clone / version pin なし
- `setup.sh` の再現性が保証されていない

**References:**
- `docs/references/harness-engineering-best-practices-2026.md`
- `docs/adr/002-pointer-design-principle.md`

### 3. DDD/プロダクションワークフロー (B-)

**Strengths:**
- 5 つのルールファイルでコーディングスタイル、Git ワークフロー、品質、テスト、委任を体系化
- PR 粒度ルール（1 PR = 1 意図、branch/commit type 一致）
- soak time（develop→main 半日、infra 1 営業日）
- post-merge 検証、follow-up fix 制限
- Tiered Review System (FULL/LIGHT/EXEMPT)

**Weaknesses:**
- **LIGHT tier 自己例外化**: `pr-ci-review-gate.sh:104` でこのリポジトリ自身を常に LIGHT に強制。README が約束する Codex second opinion が不要になる矛盾
- Operationally Ready チェックリストが手動確認のまま（hook 自動化されていない）

### 4. AI 駆動開発の自動化 (B)

**Strengths:**
- Claude Code 60% / Codex CLI 40% の委任モデルが成熟
- コンテキスト予算ゲート（read/write/agent 各段階で閾値制御）
- Codex CLI 1 タスク制限の自動強制（codex-task-gate + codex-task-release）
- AI 自己バイパス防止（block-state-file-tampering + block-state-file-tampering-bash）
- レビューパイプライン自動化（code-reviewer → Codex CLI → PR merge gate → VERIFY）
- worktree stale base 検出（本セッションで全面禁止→条件付きに改善）

**Weaknesses:**
- `pr-guard.sh` 内で MCP Codex を推奨する文言（block-codex-mcp.sh と矛盾）
- state file 更新の共通 helper が未整備（同じ flock パターンが 8+ ファイルに分散）

### 5. セキュリティ・品質 (C)

**Strengths:**
- shell injection 防止の基本方針（環境変数経由、string interpolation 禁止）
- state file flock 統一（本セッションで 5+4 ファイル修正）
- 保護ブランチ（develop/main/master 削除禁止）
- develop ベースブランチ強制 hook（本セッションで新規追加）

**Weaknesses:**
- `settings.json` の `Bash(npx:*)` 許可がベストプラクティス（npx 禁止）と矛盾
- `record-codex-review.sh`, `verify-pr-review.sh`, `reset-factcheck.sh` に flock 未使用が残存
- `stop-test-gate.sh` に `bash -c "$TEST_CMD"` の shell interpolation
- `scripts/verify-pr-review.sh` に変数直接埋込みの python3 -c

---

## Remaining Issues (to be addressed in next sessions)

### HIGH (3 items)

| # | Issue | File(s) | Impact |
|---|-------|---------|--------|
| H-1 | LIGHT tier 自己例外化 | `hooks/pr-ci-review-gate.sh:104`, `hooks/block-merge-without-review.sh:48` | レビュー厳格さの崩壊 |
| H-2 | state file flock 未統一（残存） | `hooks/record-codex-review.sh`, `scripts/verify-pr-review.sh`, `hooks/reset-factcheck.sh`, `hooks/block-manual-merge-ops.sh` | race condition |
| H-3 | npx 許可 vs ベストプラクティス矛盾 | `settings.json:24`, `docs/references/harness-engineering-best-practices-2026.md:18` | サプライチェーンリスク |

### MEDIUM (5 items)

| # | Issue | File(s) | Impact |
|---|-------|---------|--------|
| M-1 | Stop hook が repo 全体テスト実行（ADR-003 不整合） | `hooks/stop-test-gate.sh:70,112` | セッション遅延 |
| M-2 | shell interpolation 残存 | `hooks/stop-test-gate.sh:73,112`, `scripts/verify-pr-review.sh:106` | injection リスク |
| M-3 | Codex MCP 推奨文言の矛盾 | `hooks/pr-guard.sh:61` | UX 混乱 |
| M-4 | third-party 未固定 | `setup.sh:52,64` | 再現性・供給網リスク |
| M-5 | flock パターン分散（共通 helper 未整備） | 8+ files | 保守性 |

---

## Priority Recommendations (4 items)

### P1: Tiered Review 自己例外化の解消
- `pr-ci-review-gate.sh` の meta-task exemption (L98-107) を削除
- このリポジトリでも FULL/LIGHT を変更内容ベースで正しく判定
- **Why**: レビューゲートの信頼性が根幹から崩れる

### P2: State file 共通 helper + flock 統一完了
- `~/.claude/lib/state_file.py` を作成、`locked_update(path, updater_fn)` パターンを提供
- 残存 4 ファイル + 既存 8 ファイルを共通 helper に移行
- **Why**: race condition の根本解決 + 保守性向上

### P3: npx 許可削除 + third-party version pin
- `settings.json` から `Bash(npx:*)` を削除
- `setup.sh` で gstack を特定 tag/commit に pin、uipro-cli を version 指定
- **Why**: サプライチェーン攻撃リスクの排除

### P4: README/ADR/Runtime 差分解消
- Stop hook を change-related tests に限定（ADR-003 準拠）
- `pr-guard.sh` の Codex MCP 推奨文言を削除（delegation.md 準拠）
- shell interpolation を環境変数経由に置換
- **Why**: ドキュメントとコードの乖離は信頼性を損なう

---

## Session Achievements (2026-03-24)

| PR | Issue | Content |
|----|-------|---------|
| #79 | #74 | 全 hook stderr 出力統一 |
| #80 | #77 | develop ベース hook 強制 |
| #81 | #78 | worktree stale base 検出に置換 |
| #82 | #75 | Stop hook circular dependency 修正 |
| #83 | #76 | state file flock 統一 (5 files) |
| #88 | #84, #86 | stdout 汚染修正 (11 files) + severity regex 誤検出修正 |
| #89 | #87 | 監査 HIGH 指摘一括修正 (9 files) |

**Total: 7 PRs merged, 8 Issues closed, 30+ files modified**
