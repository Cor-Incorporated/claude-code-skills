# 品質・検証・報告ルール

## エラーゼロトレランス
検出したエラー・警告は即修正。「スコープ外」「既知」は放置理由にならない。
- 軽微(lint/型) → 即修正 / 中規模 → 別コミット / 大規模 → ユーザー確認
- コミット前: lint・型チェック・テスト全パス必須

## 完了検証
「完了」= 実装 + テスト + ドキュメント更新 + ユーザー視点での検証。部分完了は「完了」ではない。
- 報告前に元の依頼を再読し各項目のコード変更確認
- バグ修正: grepで全インスタンス→全修正→再grep残存ゼロ

## Operationally Ready チェックリスト
merge前確認: env var/secret記載、CORS/domain、Mixed Content、IAM権限、cron手動通過、migration rollback手順、Terraform plan貼付、Docker `--platform linux/amd64`

## エンドポイント修正時の必須検証 (hook: `enforce-endpoint-dataflow.sh`)
クライアント送信→APIルート処理→バックエンドaction_map→レスポンス形式、4点一致で「修正」

## ドキュメント同時更新 (hook: `enforce-doc-update-scope.sh`)
修正時は関連ドキュメントを同じPR/コミットで更新。grepで参照箇所を検索。

## Issue完了判定 (hook: `enforce-issue-close-verification.sh`)
受入基準を1つずつコード引用(file:line)+テスト結果で検証。全基準に証拠なければクローズしない。

## 報告書の事実検証 (hook: `enforce-factcheck-*.sh`)
事実主張はCLI出力・git diff・APIレスポンスで裏取り必須。推定は「（未検証）」明記。
