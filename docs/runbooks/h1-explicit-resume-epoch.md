# H1 明示続行 epoch: ローカル配備・撤収

対象は Codex の H1 hook と wrapper。Thor のゲーム修正や新しいラウンドはこの手順の対象外。作業は承認済み PR の正確な SHA を確認してから、Codex の操作を止めた時間帯に行う。

## 配備前

1. `hooks/codex/h1-stall-runtime.sh`、`scripts/lib/h1-runtime.sh` と H1 テストを承認済み SHA で確認する。`bash tests/test-h1-explicit-resume-epoch.sh` と既存 H1 テストの結果を保存する。
2. 配備中の `~/.codex/hooks/h1-stall-runtime.sh`、`~/.claude/scripts/lib/h1-runtime.sh`、`~/.codex/hooks.json` を時刻付きで別々にバックアップし、各ファイルの `shasum -a 256` を記録する。現行 H1 本体には kotoba-robocon 限定の期限付き `budget=0` 例外があるため、repo の素の hook を rollback 元と取り違えない。state と台帳は削除・初期化しない。
3. `~/.codex/hooks.json` の PreToolUse には `protect-branches-codex.sh`、`h1-stall-runtime.sh` の順で 2 本あることを確認する。この順序と各 handler の定義を維持する。

## 配備と trust

1. 新しい H1 本体と wrapper を先に隔離環境で検証してから、`~/.codex/hooks/h1-stall-runtime.sh` と `~/.claude/scripts/lib/h1-runtime.sh` へ配備する。フル `setup.sh` は他の settings・skills も更新するため、H1 だけを配備する場合は対象ファイルを個別に更新する。**repo の素の H1 本体をコピーすると現行の臨時例外も消える**。作業を止めた切替時間帯に配備・trust・読戻しを連続実行し、失敗時は直ちに一時例外付きバックアップへ戻す。
2. `python3 scripts/register-codex-h1-hooks.py ~/.codex/hooks.json ~/.codex/hooks` で UserPromptSubmit に**同じ H1 本体**を登録する。`setup.sh` もこの登録器を呼ぶ。登録器は既存の PreToolUse と他 event を維持し、既存設定に PreToolUse H1 が無ければ変更せず失敗する。新規設定では PreToolUse の protect→H1 と UserPromptSubmit H1 を作る。UserPromptSubmit の matcher は不要。`bash tests/test-register-codex-h1-hooks.sh` の陰性・冪等テストを通す。
3. Codex CLI の `/hooks` で新しい UserPromptSubmit hook を review・trust する。既存 PreToolUse 2 本も有効・trusted であることを同じ画面で確認する。Codex は非 managed hook の現在の定義 hash ごとに trust を記録する。`config.toml` の `trusted_hash` を手編集せず、`--dangerously-bypass-hook-trust` を配備の証拠にしない。既存 pair15 は位置と enabled を照合するだけで hash の検証にはならない。
4. 配布元・配備先の SHA 一致、`hooks.json` の 3 登録、`/hooks` の trust 状態を読み戻す。隔離 fixture で fork の親累積除外・子消費計上、明示続行だけの reset、hook と watchdog の同一判定を確認する。実経路は安全な読取コマンドと H6 台帳の reset/判定行で確認し、新しいゲームラウンドは実行しない。

公式 [Codex Hooks 文書](https://learn.chatgpt.com/docs/hooks)は hook payload の `session_id`、`model`、`turn_id`、UserPromptSubmit の `prompt` を記載する一方、transcript 形式は安定した hook interface ではないと明記する。fork metadata や rollout の内部 JSON だけを恒久判定の唯一の根拠にしない。

## 臨時例外の撤収

素の恒久 H1 本体への切替は、現行の inline `budget=0` パッチの暫定撤収でもある。恒久 H1 が配備・trusted となり、対象の明示続行による新 epoch と対象外の通常 block を実経路で読み戻したときに撤収を確定する。現行例外は **2026-09-30 00:00 JST** に失効する。撤収後も新 UserPromptSubmit 登録を残し、H1 本体の source/deployed SHA 一致、他 repo への例外非波及、hook と watchdog の一致を再確認する。未登録の旧 `h1-kotoba-budget-relief.sh` も登録の有無を確認して整理する。Thor の作業成果は例外撤収の代替証拠にしない。

## Rollback

判定・trust・配備 readback のいずれかが失敗したら、新 UserPromptSubmit 登録を外し、配備直前に保存した H1 本体、wrapper、`hooks.json` を戻す。**旧 hook は新しい `budget_epoch_spend_usd` を理解せず、同じ state の旧 `spend_usd` を読んで再停止し得る**。ロールバック後に `/hooks` で PreToolUse 2 本の trust と安全な読取経路を再確認し、停止状態を報告する。state と台帳は削除・書換えしない。臨時例外の期限後は、古いバックアップから `budget=0` を再導入しない。
