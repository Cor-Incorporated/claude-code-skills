# Hook Deployment Integrity

## エピック参照（全セッション必読）
GitHub Issue #130: hookデプロイメント検証の構造的欠陥
- hook追加時は「スクリプト作成 + ~/.claude/hooks/コピー + settings.json登録」を1 PRに含める
- 「コードがある」≠「動作する」— デプロイ検証はコード品質検証と独立したチェックポイント

## hookデプロイ3要件（全て満たさないと「実装完了」ではない）
1. `hooks/xxx.sh` がプロジェクトに存在する
2. `~/.claude/hooks/xxx.sh` にインストール済み（setup.sh経由）
3. `~/.claude/settings.json` の適切なmatcher/eventに登録済み

## Issue完了判定（hookタイプ）
- [ ] スクリプトが hooks/ に追加された
- [ ] setup.sh 再実行で ~/.claude/hooks/ にコピーされる
- [ ] settings.json にmatcher/event登録が追加された
- [ ] hookが実際に発火することを確認（トリガー操作→stderrメッセージ確認）
