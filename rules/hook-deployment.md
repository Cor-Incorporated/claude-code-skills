# Hook Deployment Integrity

## エピック参照（全セッション必読）
GitHub Issue #130: hookデプロイメント検証の構造的欠陥
- hook追加時は「スクリプト作成 + ~/.claude/hooks/コピー + settings.json登録」を1 PRに含める
- 「コードがある」≠「動作する」— デプロイ検証はコード品質検証と独立したチェックポイント
- 正本: `docs/CANONICAL-STATE.md`（23 登録 / hard block 4 / ADR-006）
  この数値は `tests/test-pairs-link.sh` の pair13 が CANONICAL-STATE.md と機械照合する。
  片方だけ変えると両側の値を挙げて落ちる（2026-09-01: 本行が 18 のまま正本 20 と乖離していた）。

## hookデプロイ3要件（全て満たさないと「実装完了」ではない）
1. `hooks/xxx.sh` がプロジェクトに存在する
2. `~/.claude/hooks/xxx.sh` にインストール済み（setup.sh経由）
3. `~/.claude/settings.json` の適切なmatcher/eventに登録済み

## hook 新設の入場料（ADR-006 恒久化。要件 4-6 なしにマージしない）
4. 防御台帳: 発火時に ~/.claude/hooks/ledger/guard-ledger.jsonl へ 1 行追記
   （{"ts","hook","event","decision","cmd_head"}。実装は harness H6 が正）
5. 陰性テスト: 既知バグ注入で block になることの実測記録を導入 PR に貼る
6. 廃止条件: 90 日発火ゼロ or 誤検知率 50% 超で退役 issue 自動起票（H6）
既存ハードブロック 4 本（git-push-guard / protect-branches /
block-local-hooks-write / validate-no-local-hooks)は tail-risk 型 —
台帳は「破滅の不在」の消極証明で代替可（C14 適用除外）だが、台帳追記だけは後付けする。

## Issue完了判定（hookタイプ）
- [ ] スクリプトが hooks/ に追加された
- [ ] setup.sh 再実行で ~/.claude/hooks/ にコピーされる
- [ ] settings.json にmatcher/event登録が追加された
- [ ] hookが実際に発火することを確認（トリガー操作→stderrメッセージ確認）
- [ ] 防御台帳への配線（block 権限 / 完了判定検証器は必須）
- [ ] 陰性テストの red 実測記録が PR にある
- [ ] 廃止条件が宣言されている
