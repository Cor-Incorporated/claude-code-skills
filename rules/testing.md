# テスト要件

## 検証は境界被覆で決まる（カバレッジ 80% は維持するが境界被覆の代理にしない）
- バッチ cycle には「マージ前の実環境貫通 1 本」（実画面・実機・実通話・実 LLM）を関門化
- 新イディオムは 1 実装を実運用条件まで検証してから横展開
- 破れた境界は同一 PR で恒久ゲート化
- 着手時に境界カタログ 9 分類で点検: mock↔実LLM / client↔API / 宣言↔実機 /
  env・IAM / 短時間↔長寿命 / 単リポ↔結合 / 外部API / 検証器自身 / 基準層
- fix スパイクは 3 分解（pre-merge 対応 / 実測発見 / 着地後手戻り）で評価（C18）

## カバレッジ80%以上（ユニット + 統合 + E2E）

## テストレベル: curlテストを「E2E完了」と報告禁止。E2Eはブラウザ検証を伴う場合のみ。
- Unit: pytest/jest / Integration: curl/httpx / E2E: Playwright/手動ブラウザ

## TDD: RED→GREEN→IMPROVE→カバレッジ確認

## 反証可能性
Bug X存在時にテスト失敗することを証明する。詳細は `/test-falsify` スキル参照。

## エージェント: tdd-guide(新機能), e2e-runner(Playwright)
