# テスト要件

## カバレッジ80%以上（ユニット + 統合 + E2E）

## テストレベル: curlテストを「E2E完了」と報告禁止。E2Eはブラウザ検証を伴う場合のみ。
- Unit: pytest/jest / Integration: curl/httpx / E2E: Playwright/手動ブラウザ

## TDD: RED→GREEN→IMPROVE→カバレッジ確認

## 反証可能性
Bug X存在時にテスト失敗することを証明する。詳細は `/test-falsify` スキル参照。

## エージェント: tdd-guide(新機能), e2e-runner(Playwright)
