# Git & CI/CD

## 保護ブランチ: develop, main, master 削除禁止・直接push禁止（PR経由）
命名: `feat/<説明>`, `fix/<説明>`, `refactor/<説明>`, `chore/<説明>`

## コミット
`<type>: <description>` (feat/fix/refactor/docs/test/chore/perf/ci/release)
マージ: デフォルト`--merge`、`--squash`は明示指示時のみ

## PR粒度ルール（監査2026-03-10追加）
- **1 PR = 1意図**: app変更とinfra/config変更は分離する
- **branch名とPR titleのtype一致必須**: `fix/`ブランチから`feat:` PRを出さない
- **1 commitに複数意図を混ぜない**: feat+fixの同居禁止
- **feat PRにはtest commitを含める**: テストなしのfeat mergeは原則禁止
- **release PRは統合のみ**: 機能追加をrelease PRに混ぜない

## follow-up fix制限（監査2026-03-10追加）
- fix PRを作る際、どのPR/commitのfollow-upかをbody/subjectに明記する
- **同一feature系統のfollow-up fixが2本連続 → feature freeze発動**
  - 新規feat PRの作成を停止し、stabilizationに集中する
  - 安定化確認後にfreeze解除
- follow-up fixの元PRにroot causeとregression testの有無を追記する

## soak time（監査2026-03-10追加）
- **develop→main release PR前**: develop上で半日以上の安定期間を置く
- **infra/migration/Terraform変更**: 1営業日以上のsoak time必須
- schedule/deploy workflowを追加した場合: 最低1回の手動smoke通過を確認してからmerge

## CI/CDオールグリーン必須
PR後: `gh pr checks`全グリーン + CRITICAL/HIGHゼロまで完了ではない
- CIは**merge gate**として使う（merge後の警報ではない）
- schedule workflow failureは翌日まで放置禁止
- merge後にschedule/cron workflowが壊れたら、次のmergeを止めて修正する

## post-merge検証（監査2026-03-10追加）
- migration/Terraform/Cloud Run/release workflowを含む変更は、PRごとにpost-merge validation手順を持つ
- 本番障害対応のfixをmergeした場合: 再発防止テストまたは監視を即追加
- 同種follow-up fixが2本連続 → stabilization day発動（上記「follow-up fix制限」参照）

## レビュータイムスタンプ検証（pushごと必須）
修正pushのたびに、レビューが最新pushより後であることを確認:
1. `gh pr view --json updatedAt` で最終push時刻を取得
2. `gh api repos/{owner}/{repo}/pulls/{pr}/reviews` でレビュー時刻を取得
3. **review.submittedAt > 最終push時刻** でなければ再レビュー必要
4. 古いレビューのみでマージしない

## スキル提案
リクエスト受信時、フェーズ判断し関連スキルを提案（スキル指定済み/単純タスクは省略）
フェーズ: 新規→A, 機能追加→B, バグ→C, 改善→D, テスト→E, デプロイ→F, レビュー→G, 設計→H, UI→I, ドキュメント→J, API→K, 認証/決済→L
