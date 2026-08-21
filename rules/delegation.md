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
委任は handover skill の契約 10 欄と H8 発射前補助 7 欄が必須。
one-shot 委任（検収往復なし）は禁止。

契約 10 欄の欄名は正本と一字一句一致させる:

1. 停止条件と最大反復
2. 報告間隔 / 無進捗タイムアウト
3. 課金上限
4. 発射前の実現可能性チェック
5. 人間ゲート列挙
6. 反証可能な完了条件
7. 事前スパイク回答欄
8. 完了条件の検査
9. 追加を提案しない
10. 強制点の実測表

H8 発射前補助 7 欄は契約 10 欄とは別枠で、各欄 20 文字以上:

### 一次資料
Issue・ADR・仕様のパスまたは URL と、どの要求を抽出したかを書く。

### 要求インベントリ
実装と照合する要求を全件列挙し、省略した要求は理由とともに記録する。

### 突合表
各要求と受入基準、実測証跡、未検証の限界を対応表で両側照合する。

### 標準質問
ユーザー像・審美・LLM 挙動境界・安全境界・セキュリティ境界を実装前に確認する。

### 北極星
目的到達を測るメトリクスと測定周期を書き、活動量だけを完了根拠にしない。

### 反証軸
F1 の軸・真理値、F2 の事故入力・再現入力、F3 の片側変異のいずれかを実装前に記載する。

### 撤収
成果の回収先と `active / recover / preserve / retire` のいずれかを書く。

これは宣言形式の強制であり、内容の真実性や実装前に書かれたことまでは機械判定できない。

## 診断プロトコル（可視化のみ）

これは可視化であり、hook・workflow・required check による強制ではない（C9 適用限界）。
修正前に、仮説を最安で壊す全体クエリを 1 本打つ。

- fleet 分布: 対象全体を状態・鮮度・tenant/org 別に集計し、逸脱数を先に出す。
- production callsite 数: production entrypoint 配下を `rg` し、実呼出し件数を先に数える。
- 実行 role: read-only query で `current_user` と `rolbypassrls` を確認する。

本番接続・資格情報・有料実行は人間ゲートを越えない。

## Git 履歴のツール帰属（可視化のみ）

AI が作成する非 merge commit の末尾に、次の trailer を 1 行記録する。

`Agent-Lane: <claude-code|codex|cursor|opencode>`

これは可視化であり強制ではない。Claude Code の Co-Authored-By は削除せず併記する。
trailer が無い、値が不正、または複数値が競合する commit は H10 で unknown として数える。

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
