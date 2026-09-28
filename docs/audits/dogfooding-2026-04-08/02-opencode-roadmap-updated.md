# OpenCode 実装計画 v2：Dogfooding 結果を反映した更新版
**前版**: `OpenCode 実装計画：dev ブランチの本番適用と機能移植ロードマップ.md`
**更新日**: 2026-04-08
**更新理由**: CC vs OC Dogfooding テスト（2026-04-07）の結果を反映

---

## 前版からの変更点サマリー

1. **Phase 1 の成功条件を更新**: guardrail.ts が 676 行 → 1444 行に進化済み。31 エージェント、30 コマンドが利用可能
2. **Phase 4-5 を大幅縮小**: コマンド 30 本・エージェント 31 体が既に実装済みで、移植作業のほとんどが完了している
3. **Phase 6 に Dogfooding で判明したバグ修正を追加**
4. **新規 Phase 8 を追加**: 実プロジェクトでのプロダクション開発能力検証

---

## 現状の正確な理解（2026-04-08 時点）

### 実装パリティの進捗

| カテゴリ | CC | OC (dev) | 前版の想定 | 実態 |
|---------|----|----|----------|------|
| コマンド | 17 本 | 30 本 | 9 本 → 移植必要 | **既に CC の 176% を実装** |
| エージェント | 26 体 | 31 体 | 6 体 → 移植必要 | **既に CC の 119% を実装** |
| ガードレール | 69 hooks | guardrail.ts 1444 行 | 676 行 → 拡張必要 | **2.1x に拡張済み** |
| ルール | 7 ファイル | AGENTS.md + opencode.json | 未移植 | プロジェクト AGENTS.md で対応 |

### 設定ロード順序（前版から変更なし）
`opencode-live-guardrails-wrapper` → `OPENCODE_CONFIG_DIR` → guardrails profile の opencode.json がグローバルを上書き。

### Dogfooding で判明した新事実

1. **OC のガードレールは CC より確実に動作する**: 型安全な TypeScript vs shell script の差が出た
2. **OC のシークレット保護は CC より強い**: `.env*` パターンの deny() が CC には存在しない
3. **OC の状態ファイル破損耐性が確認済み**: .catch() フォールバックで graceful degradation
4. **OC のサブエージェントへのガードレール継承が実証済み**: 3 層ブロック（直接/shell/サブエージェント）

---

## 更新されたフェーズ構成

### Phase 1: dev profile を本番に切り替える（前版から変更なし）
前版と同一。wrapper の exec 先を fork → dev に切り替え。
**成功条件を更新**: 31 エージェント + 30 コマンド + guardrail.ts 1444 行が実効設定になること。

### Phase 2: グローバル設定の整合（前版から変更なし）
`~/.config/opencode/opencode.jsonc` の `git *: allow` 削除、model/autoupdate 明示化。

### Phase 3: グローバル AGENTS.md（前版から変更なし）
`~/.config/opencode/AGENTS.md` に CC の rules/ 相当を移植。

### Phase 4: コマンド移植 → **大幅縮小**
前版では `/bugfix`, `/tdd`, `/e2e` 等を移植する計画だったが、dev ブランチに以下が**既に存在**:

**既存 (30 本)**: blog, bugfix, build-fix, code-review, delegate, e2e, explain-project, gemini, handoff, implement, investigate, learn, plan, plan-to-checklist, provider-eval, refactor-clean, review, ship, tdd, test, test-coverage, test-report, ui-skills, update-codemaps, update-docs

**残作業**: CC にあって OC にないコマンドの差分確認のみ。実質的に Phase 4 は**完了済み**。

### Phase 5: エージェント移植 → **大幅縮小**
dev ブランチに以下が**既に存在** (31 体):

api-designer, architect, backend-developer, build-error-resolver, cloud-architect, code-reviewer, database-administrator, database-optimizer, deployment-engineer, doc-updater, e2e-runner, golang-pro, implement, incident-responder, investigate, mobile-developer, planner, provider-eval, python-pro, refactor-cleaner, review, security, security-engineer, security-reviewer, sql-pro, swift-expert, tdd-guide, technical-writer, terraform-engineer, typescript-pro, websocket-engineer

**残作業**: CC の skills/ にあって OC にないエージェントの差分確認のみ。Phase 5 も**ほぼ完了**。

### Phase 6: 高度フック追加 → **Dogfooding バグ修正を追加**

前版の内容に加え、Dogfooding で判明した以下を対応:

1. **cherry-pick ブロックの発火確認**: guardrail.ts L697-699 の regex は正しいが、LLM が Bash 実行前に止まるケースへの対策（advisory メッセージの追加？）
2. **version baseline regression の発火確認**: deny() 内の version 比較ロジックが、LLM が edit を試みない場合に到達しない問題
3. **Permission ダイアログのシナリオ固有メッセージ化**: 汎用 "Allow?" ではなく、cherry-pick なら "cherry-pick は推奨されません" 等のコンテキスト付き

### Phase 7: 残バグ修正（前版から変更なし）
Issue #55, #54, factcheck.test.ts

### Phase 8: プロダクション開発能力の実証 ← **新規追加**
Dogfooding レポートで「最も重要な欠落」として指摘された、実プロジェクトでの開発フルサイクルテスト。

詳細は `03-production-scenario-test-plan.md` を参照。

---

## 更新された推奨実行順

| 順序 | Phase | 所要時間 | 状態 |
|------|-------|---------|------|
| 1 | Phase 1: dev 切り替え | 30 分 | 未着手 |
| 2 | Phase 2 + 3: 設定 + ルール | 2 時間 | 未着手 |
| 3 | Phase 7: バグ修正 | 2 時間 | 未着手 |
| 4 | Phase 6: フック拡張 + Dogfooding 修正 | 3 時間 | 未着手 |
| 5 | Phase 8: プロダクション開発テスト | 4 時間 | 未着手 |
| — | Phase 4: コマンド差分確認 | 30 分 | **ほぼ完了** |
| — | Phase 5: エージェント差分確認 | 30 分 | **ほぼ完了** |

---

## 完了イメージ（更新）

Phase 1-3 完了時点で、前版の見込み 50% → **実態は 75% 以上**（コマンド・エージェントが既に dev に存在するため）。

Phase 4-7 完了で **90%**。

Phase 8 完了で、ガードレールだけでなく**開発能力としても CC / Codex と同等**であることを実証済みの状態。

Co-Authored-By: Oz <oz-agent@warp.dev>
