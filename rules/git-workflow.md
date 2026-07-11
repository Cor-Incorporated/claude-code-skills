# Git & CI/CD

## ブランチ (hook: `protect-branches.sh`, `git-push-guard.sh` が force-push/直接pushをブロック)
保護: develop, main, master。削除禁止・直接push禁止（PR経由）
命名: `feat/<説明>`, `fix/<説明>`, `refactor/<説明>`, `chore/<説明>`

## コミット
`<type>: <description>` (feat/fix/refactor/docs/test/chore/perf/ci/release)
マージ: デフォルト`--merge`、`--squash`は明示指示時のみ

## PR粒度ルール
- 1 PR = 1意図 / branch名とPR titleのtype一致 / feat PRにはtest含める
- release PRは統合のみ。1 commitに複数意図を混ぜない

## follow-up fix（ガイダンス）
- fix PRにfollow-up元PR/commitを明記
- 同一feature系統の連続follow-upは一旦立ち止まって設計を見直す

## soak time（ガイダンス）
- develop→main: 半日以上空けるのが望ましい / infra・migrationは1営業日以上

## CI/CD
`gh pr checks`全グリーン + CRITICAL/HIGHゼロを確認してからマージする。マージ安全性はGitHub branch protectionが担保する。

## post-merge検証（ガイダンス）
migration/Terraform/release workflow変更後はpost-merge validation手順を実施する

## レビュー（ガイダンス）
pushごとにreview.submittedAt > 最終push時刻を確認する。古いレビューのみでマージしない。

## スキル提案
リクエスト受信時、フェーズ判断し関連スキルを提案（スキル指定済み/単純タスクは省略）
フェーズ: 新規→A, 機能追加→B, バグ→C, 改善→D, テスト→E, デプロイ→F, レビュー→G, 設計→H, UI→I, ドキュメント→J, API→K, 認証/決済→L
