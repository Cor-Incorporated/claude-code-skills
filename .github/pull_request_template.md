## Summary

## H5 admission (block-capable guard / completion verifier only)

- [ ] **H5-guard: no** — this PR does **not** add/change a block-capable guard or completion verifier
- [ ] **H5-guard: yes** — fill the three sections below (required check `h5-admission` will fail if incomplete)

### 陰性テスト (negative test — known-bad → red measured)

```
# command + expected fail / red log
```

### 台帳 (H6 ledger wiring)

How fire events append to `guard-ledger.jsonl` / `aidd_ledger_append`:

### 廃止条件 (retirement)

e.g. 90 days zero fires / FP rate >50% → retirement issue

## 実環境貫通（C11 / Track B B1）

故障は自動検証の外側（実画面・実機・実 LLM・実 env・長寿命・実引数順）に集中する。
「テストが green」だけでは完了にしない。

- [ ] この変更が触れた境界のうち、**実環境を 1 本通した**
  - 通した境界: <!-- 例: 実 hook 入力 / 実 LLM / 実 CI ランナー / 該当なし -->
  - 実行したコマンド / 操作:
  - 生出力（要点）:
- [ ] **該当なし**（実環境を持たない変更 / docs のみ / 人間ゲート待ち）。理由:

## 未知の依存・API（C16 / Track B B4）

- [ ] このリポで**初出**の依存・API・バージョンを使った場合、**実物を 1 回照合**した（レジストリ / 公式ドキュメント / 実行）
  - 照合結果: <!-- URL またはコマンド出力の要点 -->
- [ ] **該当なし**（初出の依存・API を使っていない）

## 完了条件の形式（Track B B2）

この PR の「完了」は次のいずれか（複数可）。**禁止**: 文字列 grep のみ / 設定値一致のみ / 行数 ≥ N / 「コマンドが成功した」だけ。
正本: https://github.com/Cor-Incorporated/aidd-governance/blob/main/design/ops/completion-criteria-spec.md（F1 / F2 / F3）

- [ ] **F1** 入力空間の列挙（判定・フィルタ・ガード）— 真理値表または軸の明示
- [ ] **F2** 失敗モードの再現（是正）— 以前落ちていた入力が期待どおりになった生出力
- [ ] **F3** 両側照合（二重管理）— 片側を壊すと両方の値が失敗出力に出る
- [ ] **該当なし**（docs のみ / 形式変更のみ 等）。理由:

## Test plan

- [ ]
