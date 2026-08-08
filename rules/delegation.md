# エージェント委任 → ADR-004

## 担当振り分け
- 対話・判断・設計 → Claude Code
- 2+独立タスク → Agent Team (TeamCreate)
- 1タスク+長時間+自律+大規模 → Codex CLI経路C (唯一のCodex条件)
- レビュー → code-reviewer + Codex CLI経路A
- GitHub/Supabase操作 → Codex CLI
- 詳細: `docs/adr/004-codex-delegation-model.md`

## 並列上限
サブエージェント5-7 / Bash3-4 / Codex CLI **1** / Agent Team最大5 / 合計7以下（根拠 = 当日中に検収できる量。検収実績で較正）。検収不能時間帯の完了は「完了候補」として翌朝の検収キューへ

## 委任契約
委任は handover skill の契約 6 欄必須。one-shot 委任（検収往復なし）は禁止

## Codex CLI 3経路 → `scripts/README.md`
- 経路A: `codex exec review` (レビュー)
- 経路B: ハンドオーバードキュメント → ユーザー経由
- 経路C: `codex-parallel.sh` / `codex-orchestrate.sh` (実装)

## 禁止事項（ガイダンス）
- 状態ファイルの直接書き込みは避ける
- Codex MCPは使用せずCodex CLI経路を使う
- コンテキスト予算を意識して不要な大量読み込みを避ける

## レビューパイプライン（ガイダンス。マージ安全性はGitHub branch protectionが担保）
- ソースコード変更 → code-reviewer + Codex CLI
- CI/config/docs変更のみ → code-reviewer のみ
- docs/chore/ci ブランチ → 省略可

## エージェント一覧
planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, Explore, general-purpose/haiku

## 即時使用（指示不要）
複雑な機能→planner / コード作成後→code-reviewer / バグ修正→tdd-guide / ビルド失敗→build-error-resolver

## コンテキストウィンドウ管理
- 残り20%: 新規タスク禁止、完了に集中
- 残り10%: メモリ保存→継続セッション提案
- コンパクティング後: TaskListで状態確認して再開
