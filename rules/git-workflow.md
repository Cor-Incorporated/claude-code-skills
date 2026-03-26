# Git & CI/CD

## ブランチ (hook: `protect-branches.sh`, `enforce-develop-base.sh`)
保護: develop, main, master。削除禁止・直接push禁止（PR経由）
命名: `feat/<説明>`, `fix/<説明>`, `refactor/<説明>`, `chore/<説明>`

## コミット
`<type>: <description>` (feat/fix/refactor/docs/test/chore/perf/ci/release)
マージ: デフォルト`--merge`、`--squash`は明示指示時のみ

## PR粒度ルール
- 1 PR = 1意図 / branch名とPR titleのtype一致 / feat PRにはtest含める
- release PRは統合のみ。1 commitに複数意図を混ぜない

## follow-up fix制限 (hook: `enforce-follow-up-limit.sh`)
- fix PRにfollow-up元PR/commitを明記
- 同一feature系統2本連続 → feature freeze発動

## soak time (hook: `enforce-soak-time.sh`)
- develop→main: 半日以上 / infra・migration: 1営業日以上

## CI/CD (hook: `block-merge-without-ci.sh`)
`gh pr checks`全グリーン + CRITICAL/HIGHゼロ必須。CIはmerge gate。

## post-merge検証 (hook: `enforce-post-merge-validation.sh`)
migration/Terraform/release workflow変更はpost-merge validation手順必須

## レビュー (hook: `enforce-review-reading.sh`, `block-merge-without-review.sh`)
pushごとにreview.submittedAt > 最終push時刻を確認。古いレビューのみでマージしない。

## スキル提案
リクエスト受信時、フェーズ判断し関連スキルを提案（スキル指定済み/単純タスクは省略）
フェーズ: 新規→A, 機能追加→B, バグ→C, 改善→D, テスト→E, デプロイ→F, レビュー→G, 設計→H, UI→I, ドキュメント→J, API→K, 認証/決済→L
