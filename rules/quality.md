# 品質・検証・報告ルール

## エラーゼロトレランス
検出したエラー・警告は即修正。「スコープ外」「既知」は放置理由にならない。
- 軽微(lint/型) → 即修正 / 中規模(ロジック変更) → 別コミット / 大規模(アーキテクチャ影響) → ユーザー確認
- コミット前: lint・型チェック・テスト全パス必須

## 完了検証
「完了」= 実装 + テスト + ドキュメント更新 + ユーザー視点での検証。部分完了は「完了」ではない。
- 報告前に元の依頼を再読し各項目のコード変更確認
- バグ修正: grepで全インスタンス→全修正→再grep残存ゼロ
- デプロイ後: HTTP200, HTTPS強制, ログエラーなし, Mixed Contentなし

## Operationally Ready チェックリスト（監査2026-03-10追加）
「feature complete」≠「merge可能」。merge前に以下を全て確認:
- [ ] env var / secret: 新規追加分がREADME/docsに記載されているか
- [ ] CORS / domain: 新規ドメインやオリジンを追加していないか
- [ ] MIME type / Mixed Content: 静的アセット配信が壊れていないか
- [ ] permission / IAM: GitHub Actions / GCP / AWSの権限は足りているか
- [ ] scheduler / cron: 新規追加のschedule workflowが1回は手動通過しているか
- [ ] migration / DDL: rollback手順が明記されているか
- [ ] Terraform / IaC: plan結果をPRに貼り付けているか
- [ ] Docker: `--platform linux/amd64` (Apple Silicon→GCP)、`--build-arg`にhttp://なし

## repo最低基準（監査2026-03-10追加）
- workflow 0件のrepoは開発進行前にCI最低限セットを導入:
  - `pull_request`トリガー: lint + test
  - `push to main`トリガー: build or smoke
- **security / payment / data migrationを含むrepoはworkflow未整備のまま開発禁止**
- 対象repo（2026-03-10時点）: hack-payment-system, stt-api, vdes-fleet-network 等

## エンドポイント修正時の必須検証
「修正した」と報告する前に、フルデータフローを確認:
1. クライアント: 何を送信する？(コンポーネントのfetch呼び出しを確認)
2. APIルート: リクエストをどう処理する？(route.tsの中身)
3. バックエンド: そのアクションを受け付ける？(action_mapを確認)
4. レスポンス: 形式はクライアントの期待と一致する？(destructuringを確認)
4つ全て一致しなければ「修正」ではない。

## ドキュメント同時更新
修正を加えたら、関連する全ドキュメントを同じPR/コミットで更新する。
grepで参照箇所を検索してから報告する。

## Issue完了判定
「関連コードが存在する」≠「受入基準を満たしている」
- Issue本文を読み、受入基準を1つずつリストアップ
- 各基準にコード引用(file:line)+テスト結果で検証
- 全基準に証拠がなければクローズしない

## Docker注意
- `--build-arg`にhttp://なし / `--platform linux/amd64`(Apple Silicon→GCP)

## 報告書の事実検証
事実主張はCLI出力・git diff・APIレスポンスで裏取り必須。
- 根本原因断定 → コード引用+テスト結果を同一セクションに
- コード変更主張 → ファイルパス+行番号/diff引用
- タイムライン因果 → タイムスタンプ含める
- 推定は「（未検証）」明記
