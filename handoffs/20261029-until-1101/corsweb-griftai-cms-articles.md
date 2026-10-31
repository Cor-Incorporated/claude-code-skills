# Handover: corsweb2024 / griftai の CMS と記事

**作成日**: 2026-10-29 / **作成者**: Cursor クラウドエージェント / **宛先**: Claude Code Desktop / **指示者**: 寺田康佑（Cor.） / **期間**: 2026-10-29〜2026-11-01（Asia/Tokyo、両端を含む） / **ブランチ**: `cursor/handoff-until-1101-6413`

SUPERSEDE は寺田康佑だけが宣言できる。宣言するときは、この第 1 行を `SUPERSEDE: 寺田康佑 YYYY-MM-DD 理由` に置き、同じターンで後継ファイルを撃火する。後継が無い宣言は無効である。旧ファイルは Archive へ移さない。

## Goal

corsweb2024 と griftai の CMS・記事について、item21 の SHA が一致したローカル原稿の継続作業を進める。公開と main への反映は寺田康佑の後に行う。

## Success

報告に SHA 計算コマンド、計算値、既知値 `{SHA}` との一致行がある。一致行が無い状態での記事・CMS の編集は 0 である。公開操作、main への push、note / Qiita / X への投稿は 0 である。ハッシュ入力の手順が見つからない場合は、読み取りだけを残して編集 0 で停止している。

## 5W1H

### Who

指示者は寺田康佑（Cor.）。実行者はゲート Mac の Claude Code Desktop。この包の作成者は Cursor クラウドエージェントである。検収者は寺田康佑。Grok Bot は実装と配信を行わない。11/1 の返却を Grok のセッションへ渡すのは寺田康佑である。

### What

corsweb2024 と griftai の CMS と記事のローカル原稿。note への転載、新しい note key、管理投稿は期間中に行わない。P0-S1 `n083decbc281b` の公開は寺田だけが行う。

### When

着手は 2026-10-29。新規の実装と配信は 2026-11-01 23:59 Asia/Tokyo で止める。報告を揃えて寺田が Grok へ返すのは、その停止の後である。

### Where

ゲート Mac 上の corsweb2024 と griftai。この VM では toplevel 未確認。照合値は item21 の SHA `{SHA}`。

依頼ファイルは `~/Desktop/Claude_Code依頼_20261029_corsweb-griftai-cms-articles.md`。報告ファイルは `~/Desktop/Claude_Code報告_20261029_corsweb-griftai-cms-articles.md`。

### Why

未同期のゲート Mac で記事を進めた事故の再発を防ぎつつ、照合が取れたローカル原稿の継続分は Claude Code が持てるようにする。

### How

ゲート Mac で共有チェックアウトを切り替えず、`origin/<base>` から自分の worktree を切る。手順の文言は共通条項が正本である。継続対象は、その worktree の `git status --porcelain` と open PR に既にある作業だけである。継続対象が 0 件なら新しい機能を始めず停止する。コミット先はレーンのブランチである。`main`、`master`、`develop` への直 push、force push、merge はしない。30 分ごとに報告へ追記し、2026-11-01 23:59 Asia/Tokyo で止める。
最初の編集コマンドの前に SHA 照合を終える。一致が yes のときだけ、継続対象のローカル原稿を編集する。公開ボタン、本番デプロイ、main への merge は寺田の後なので、このセッションは実行しない。Header を扱う場合は前回 eyecatch を再利用する。全文 HTML と全文 Markdown の note 貼り付けは行わない。

## 確定

- 指示者は寺田康佑（Cor.）。宛先は Claude Code Desktop。作成は Cursor クラウドエージェント（この VM）が 2026-10-29 に行った。
- 期間は 2026-10-29 から 2026-11-01 まで。両端を含む。時刻の基準は Asia/Tokyo。停止時刻は 2026-11-01 23:59 Asia/Tokyo。
- この包のブランチは `cursor/handoff-until-1101-6413`。測定時の develop HEAD は `e7b4df34a62fcfe714944ccfceb68baf9c2bf99a`。
- 直近インシデント 10 件は本ファイルの「直近インシデント」節のとおり、寺田の指示として確定している。
- item21 の既知 SHA は `19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a`。
- P0-S1 の note key は `n083decbc281b`。公開者は寺田康佑。業界例は ROS2。
- smart-glasses の指示パスは `~/developer/m02-smart-glasses`。実機テストは禁止。
- ai-cluster の破壊的再起動は、寺田の確認が報告に残ってから行う。
- corsweb2024 と griftai の公開と main への反映は、寺田の後に行う。
- TimeSync E2E は partial かつ `BLOCKED_HUMAN`。デバイス実測は停止。2026-10-29 の夜に E2E を再開しない。
- Desktop の依頼は、作成者が同じターンで撃火する。Archive はしない。SUPERSEDE は寺田だけが宣言する。
- `#94` と `#454` は凍結を継続する。
- 課金上限の契約値は $50（handover skill の既定）。最大反復は 10。報告間隔は 30 分。無進捗タイムアウトは 45 分。
- オープンな衝突面として、claude-code-skills PR `#418` のファイル一覧（並列衝突節）が 2026-10-29 に実測済みである。
- 共通条項の正本は `skills/handover/common-clauses.md`（8090 bytes）である。

- 公開と main は寺田の後である。
- この期間の note / Qiita / X 管理投稿は停止である。

## 未確認

- ゲート Mac のホスト名、同期状態、各製品リポジトリの `git rev-parse --show-toplevel`。
- `~/developer/m02-smart-glasses` がゲート Mac に実在するか。大文字の `~/Developer/...` との関係。
- ai-cluster、grift CLI、corsweb2024、griftai、yomiyasu、cor-voice、cor-voice-gate、TimeSync の git remote とブランチ。
- item21 SHA のハッシュ入力（ファイル集合と順序）。この VM に item21 の手順書は見つかっていない。
- item19 / item20 / note-edit-safe のスクリプトパス。
- `#94` と `#454` の所在リポジトリ。aidd-governance は 2026-10-29 にこの VM から解決できなかった。
- 寺田が $50 以外の課金上限をこの期間に指定しているか。
- harness H1 がゲート Mac の Claude Code に配備されているか。
- 各製品リポジトリの作業ツリーに、継続すべき未コミット変更や open PR があるか。

- corsweb2024 と griftai のパス、item21 手順のファイルパス、現行 HEAD が既知 SHA と一致するか。

## 判断待ち

- ai-cluster の破壊的再起動を実行してよいか。確認文が報告に貼られるまで実行しない。
- TimeSync の `BLOCKED_HUMAN` を外すか。寺田が外すまで E2E を再開しない。
- corsweb2024 / griftai の公開、および main への反映。寺田の後まで行わない。
- item21 のハッシュ入力が手順から特定できないとき、CMS と記事を編集してよいか。特定できるまで編集しない。
- `#94` と `#454` の正本 URL。寺田が示すまで、番号だけで操作しない。
- 新しいガード、hook、workflow、required check が必要という結論の採否。提案を残して停止し、寺田が判断する。
- SUPERSEDE（依頼ファイルの無効化と後継）。寺田だけが宣言する。
- 2026-11-01 の返却後に Grok が実装を再開するか。返す条件が揃った報告を寺田が見るまで再開しない。
- 対象リポジトリに継続対象（未コミット変更または open PR）が 0 件のとき、新しい機能を始めるか。始めない。判断待ちとして停止する。

- ハッシュ入力が不明なときの編集再開。公開と main の実施者は寺田。

## 直近インシデント

本期間の拘束。10 件とも、このファイル単体で有効である。

1. **note の same-key（item20）**  
   note の更新は同じ key の下書きだけを対象にする。新しい key の下書きが出来た場合は破棄する。残す下書きは same-key だけである。
2. **note 本文の形（item19／note-edit-safe）**  
   note に全文 HTML を貼り付けない。全文 Markdown を貼り付けない。embed、cover、裸 URL を検査する。
3. **Header**  
   Header は前回の eyecatch を再利用するのを既定にする。
4. **ゲート Mac の SHA 照合（item21）**  
   ゲート Mac が未同期だった。corsweb と griftai は、編集の前に SHA を照合する。既知の item21 込み SHA は `19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a` である。計算結果がこの値と等しい記録が報告に無い間は、記事と CMS のファイルを編集しない。ハッシュ入力（対象ファイルと順序）がリポジトリの item21 手順に見つかる場合はそのコマンドを使う。手順が見つからない場合は編集せず、判断待ちとして停止する。`git status` と `git rev-parse HEAD` の読み取りは、照合の前でも記録してよい。
5. **TimeSync**  
   TimeSync の E2E は partial かつ `BLOCKED_HUMAN` である。デバイス実測は停止している。2026-10-29 の夜に E2E を再開しない。`BLOCKED_HUMAN` を寺田康佑が外すまで、夜を過ぎても E2E を再開しない。
6. **P0-S1 `n083decbc281b`**  
   改稿中である。公開は寺田康佑だけが行う。定数の引用は可。業界例は ROS2 を使う。本期間、Claude Code は note の作成・更新・公開 API を呼ばない。
7. **実行主体**  
   実装と配信の実行主体は専任 bot、Claude Code、Cursor である。Grok Bot は直実行しない。
8. **Desktop 手渡し**  
   Desktop 上の依頼ファイルは、そのファイルを書いた作成者が同じターンで Claude Code を撃火する。Archive しない。`SUPERSEDE` は寺田康佑だけが宣言できる。
9. **管理投稿の停止**  
   2026-10-29 から 2026-11-01 まで、note、Qiita、X の管理投稿は一時停止する。
10. **凍結**  
    `#94` と `#454` の凍結を継続する。実装、close、reopen、凍結解除をしない。番号が同じ別オブジェクトを操作しない。2026-10-29 の実測では、claude-code-skills の PR `#94` は MERGED の文書監査（mergedAt 2026-03-23T22:26:03Z）である。claude-code-skills に `#454` は無い。`Cor-Incorporated/aidd-governance` はこの VM から解決できない。凍結対象の所在リポジトリは未確認である。


## 触ってよいパス

- 照合完了前: 対象リポジトリでの `git status`、`git rev-parse HEAD`、item21 手順に書いてあるハッシュコマンド、手順を探す `rg`。
- 照合が既知 SHA と一致したあと: corsweb2024 と griftai の worktree 内で、`git status` または open PR に既にある CMS・記事のローカル原稿。
- `~/Desktop/Claude_Code報告_20261029_corsweb-griftai-cms-articles.md`


## 触るなパス

- 一致行が報告に無い状態での CMS・記事ファイルの保存。
- `main` への commit、push、merge。本番公開。CMS の公開操作。
- note、Qiita、X の作成、更新、公開。新しい note key。`n083decbc281b` の公開。
- 全文 HTML、全文 Markdown の note への貼り付け。
- 前回と別の Header 画像への差し替え。
- PR `#418` のファイル。ai-cluster の再起動。smart-glasses の実機。


## 並列衝突

claude-code-skills の open PR `#418`（draft、head `fix/h17-p1a-vocab`、base `develop`）が次のパスを持つ。この期間、これらのパスを編集しない。

- `hooks/README.md`
- `hooks/lib/aidd-cc-adapter.sh`
- `hooks/lib/aidd_cc.py`
- `hooks/lib/aidd_cc_controls.py`
- `hooks/lib/aidd_cc_eval.py`
- `hooks/lib/aidd_cc_text.py`
- `rules/quality.md`
- `tests/fixtures/h17-claim-phrases.json`
- `tests/test-aidd-cc.sh`

2026-09-28、共有台帳が corsweb2024 の run と ai-cluster の nohup を、無関係な claude-code-skills セッションの停止条件に混ぜた（`hooks/aidd-turn-boundary-stop.sh`）。他セッションの `~/.claude/state/async-work` 行を resolve しない。自分の `session_id` の行だけを扱う。

1 つの Claude Code セッションに複数 topic を載せない。topic ごとに Desktop ファイルを 1 枚、セッションを 1 つ、worktree を 1 つにする。

- 台帳を corsweb2024 の run と ai-cluster が共有した実績がある。このレーンは `~/.claude/state/async-work` へ書き込まない。ai-cluster レーンと同時に同じ状態ファイルを触らない。
- 記事の出口（note / Qiita / X / CMS 公開）は grift CLI の publish と同じ禁止に入る。出口のコマンドをどちらも実行しない。

実装 5 レーンと master と readme の対応は次のとおり。同じ topic の報告ファイルへ、他 topic の結果を書かない。

| topic | 依頼ファイル（Mac Desktop） | 報告ファイル（Mac Desktop） |
|---|---|---|
| `master-handoff-until-1101` | `~/Desktop/Claude_Code依頼_20261029_master-handoff-until-1101.md` | `~/Desktop/Claude_Code報告_20261029_master-handoff-until-1101.md` |
| `ai-cluster` | `~/Desktop/Claude_Code依頼_20261029_ai-cluster.md` | `~/Desktop/Claude_Code報告_20261029_ai-cluster.md` |
| `smart-glasses` | `~/Desktop/Claude_Code依頼_20261029_smart-glasses.md` | `~/Desktop/Claude_Code報告_20261029_smart-glasses.md` |
| `grift-cli` | `~/Desktop/Claude_Code依頼_20261029_grift-cli.md` | `~/Desktop/Claude_Code報告_20261029_grift-cli.md` |
| `corsweb-griftai-cms-articles` | `~/Desktop/Claude_Code依頼_20261029_corsweb-griftai-cms-articles.md` | `~/Desktop/Claude_Code報告_20261029_corsweb-griftai-cms-articles.md` |
| `yomiyasu-cor-voice-gate-pdca` | `~/Desktop/Claude_Code依頼_20261029_yomiyasu-cor-voice-gate-pdca.md` | `~/Desktop/Claude_Code報告_20261029_yomiyasu-cor-voice-gate-pdca.md` |
| `readme` | `~/Desktop/Claude_Code依頼_20261029_readme.md` | `~/Desktop/Claude_Code報告_20261029_readme.md` |

## 報告ファイル名

`Claude_Code報告_20261029_corsweb-griftai-cms-articles.md`

パスは `~/Desktop/Claude_Code報告_20261029_corsweb-griftai-cms-articles.md`。リポジトリ、メール、Slack、SNS、Grok への転送先にはしない。

報告はこの骨子で書く。リポジトリへコミットしない。

```markdown
# 報告
topic: <topic>
期間: 2026-10-29〜2026-11-01
## 実測
Evidence: <コマンド> | <生出力の要点またはログパス> | <Asia/Tokyo の時刻>
## 対象パス
test -e または git rev-parse --show-toplevel の生出力:
## 触ったパス
## 継続対象
git status と open PR:
## 送信件数
メール 0 / Slack 0 / SNS 0 / merge 0 / 本番公開 0 / note 0 / Qiita 0 / X 0
## SHA
計算コマンド:
計算値:
既知 item21: 19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a
一致: yes / no / このレーンは照合対象外
## 人間ゲート残
## 撤収 3 欄
回収コミット SHA:
残している worktree とブランチ:
判断待ち在庫（理由）:
```


## 送信禁止

このレーンを含め、2026-10-29 から 2026-11-01 までの実行で次を行わない。

- メールを送らない。下書きの送信、転送、既存メールへの返信送信を含む。
- Slack に投稿しない。スケジュール投稿、リアクション、DM を含む。
- SNS に投稿しない。X へのポスト、いいね、リポスト、DM、note、Qiita を含む。
- pull request を merge しない。`gh pr merge` を実行しない。
- 本番へ公開しない。本番デプロイ、本番への promote、CMS の公開操作、ストア公開を含む。
- `main` / `master` へ push しない。`develop` への直 push をしない。force push をしない。
- 報告ファイルをメール、Slack、SNS、Grok へ送らない。報告は Mac の Desktop に置く。11/1 に寺田康佑が Grok へ渡す。

Grok Bot への返却は寺田経由である。Claude Code が Grok へファイルを送った時点で、この節の違反である。


## 11/1にGrokへ返す条件

1. 時刻が 2026-11-01 23:59 Asia/Tokyo に達している。寺田康佑がそれより早く返却を宣言した場合は、その宣言時刻で止める。
2. `~/Desktop/Claude_Code報告_20261029_corsweb-griftai-cms-articles.md` が存在し、Evidence 行（実行コマンド、生出力の要点またはログパス、実行時刻）を含む。
3. 報告に、メール 0、Slack 0、SNS 0、merge 0、本番公開 0、note 0、Qiita 0、X 0 の件数記録がある。
4. 残っている人間ゲートと判断待ちが列挙されている。
5. 撤収 3 欄（回収コミット SHA、残している worktree とブランチ、判断待ち在庫）が書いてある。
6. 寺田康佑が報告を読み、Grok のセッションへ渡す。Claude Code は Grok へ送らない。
7. 1〜6 が揃うまで、Grok は実装と配信を再開しない。


## 失敗例→再発防止

| # | 失敗例 | 再発防止 |
|---|---|---|
| 1 | note 更新で新しい key の下書きが出来て、元の記事と別の下書きが残った（item20） | 新しい key の下書きは破棄する。残すのは same-key だけ。本期間は note の管理投稿自体を止める |
| 2 | note に全文 HTML または全文 Markdown を貼り、embed / cover / 裸 URL の検査が抜けた（item19／note-edit-safe） | 全文 HTML を貼らない。全文 Markdown を貼らない。embed、cover、裸 URL を検査してから扱う |
| 3 | Header を前回と別の画像にした | Header は前回 eyecatch の再利用を既定にする |
| 4 | 未同期のゲート Mac で corsweb / griftai を編集した（item21） | 編集前に SHA を照合する。既知値は `19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a`。不一致、またはハッシュ入力が不明なら編集しない |
| 5 | TimeSync E2E が partial / `BLOCKED_HUMAN` のままデバイス実測を続けた | デバイス実測を止めたままにする。2026-10-29 の夜に E2E を再開しない。寺田が `BLOCKED_HUMAN` を外すまで再開しない |
| 6 | 改稿中の P0-S1 `n083decbc281b` を公開した | 公開は寺田だけ。定数引用は可。業界例は ROS2。Claude Code は note API を呼ばない |
| 7 | Grok が専任の実行経路を飛ばして実装と配信を直接行った | 実行は専任 bot、Claude Code、Cursor。Grok Bot は直実行しない |
| 8 | Desktop の依頼を置いたまま撃火せず、Archive し、寺田以外が SUPERSEDE した | 作成者が同じターンで撃火する。Archive しない。SUPERSEDE は寺田だけ |
| 9 | この期間に note / Qiita / X の管理投稿を出した | 2026-10-29〜2026-11-01 は管理投稿を停止する |
| 10 | 凍結中の `#94` / `#454` を再開した。または番号が同じ別 PR を凍結対象として操作した | 凍結を継続する。所在が未確認の間は番号だけで close / reopen しない。ccs PR `#94`（MERGED の文書監査）は凍結対象の操作先にしない |


## 作業環境

- Repo: Cor-Incorporated/claude-code-skills。測定時の checkout は `/workspace`、ブランチ develop、HEAD `e7b4df34a62fcfe714944ccfceb68baf9c2bf99a`。
- この包のブランチ: `cursor/handoff-until-1101-6413`（`origin/develop` の `e7b4df34a62fcfe714944ccfceb68baf9c2bf99a` から作成）。
- Worktree（包の作成）: `/workspace/.worktrees/cursor/handoff-until-1101`。
- 現況（2026-10-29T13:36:26Z）: 製品パスは MISSING。claude-code-skills の測定時 status は空。open PR は `#418`。
- 実行環境: ゲート Mac。この VM は Desktop へコピーできない。

## 目的（1〜2行）

corsweb2024 と griftai の CMS・記事について、item21 の SHA が一致したローカル原稿の継続作業を進める。公開と main への反映は寺田康佑の後に行う。

## 経緯（3〜5行）

寺田康佑は 2026-10-29、Grok Bot の利用リミットを避けるため、2026-11-01 までの実装と配信を Claude Code へ委任すると指示した。メール、Slack、SNS の送信、merge、本番公開は禁止である。直近の note、SHA 未同期、TimeSync の `BLOCKED_HUMAN`、P0-S1、Desktop 手渡し、管理投稿、`#94` / `#454` の凍結を、各依頼ファイルへ残す。この VM には製品チェックアウトが無く、パスを確認できない委任は編集に入らない。

## 委任契約（必須）

欄名は `rules/delegation.md` と `skills/handover/SKILL.md` の契約 10 欄に合わせてある。

1. **停止条件と最大反復:** 最大反復は 10。11 回目に入る前に停止して報告する。2026-11-01 23:59 Asia/Tokyo でも停止する。人間ゲートに当たったときも停止する。反復の数え方は、同じ失敗への修正を 1 反復とする。
2. **報告間隔 / 無進捗タイムアウト:** 作業中は 30 分ごとに報告ファイルへ経過を追記する。45 分、成果物（diff、ログ、測定値）が増えないときは停止して報告する。機械強制の harness H1 がゲート Mac の Claude Code に配備されているかは未測定である。配備の有無に依存せず、この欄の時間で止める。
3. **課金上限:** $50。これは handover skill の既定値である（2026-09-27 のユーザー指示で全モデル推定 $50、`rules/delegation.md` が参照する #401）。寺田康佑による別上限の指示は、この VM では未確認である。別上限が Desktop 上の寺田の文面にあれば、その金額を優先し、報告に引用を残す。上限に達したら停止する。この VM には `~/.claude/hooks/git-push-guard.sh` が無く、H1 の機械停止はここには掛からない。
4. **発射前の実現可能性チェック:** 製品実装がこの VM で不可能であることを、パスの有無で確認した。コマンドは `git rev-parse`、`git status`、`git worktree list`、`gh pr list`、`gh pr view 94`、`gh pr view 418`、`gh issue view 454`、`gh pr view 454`、`gh repo view Cor-Incorporated/aidd-governance`、対象パスの `test -e`。結果を下に貼る。貼付のない委任は欠陥なので、ゲート Mac でも同じ確認を再実行して報告に貼るまで編集しない。

```
測定時刻: 2026-10-29T13:36:26Z
ホスト: cursor（クラウド VM。ゲート Mac ではない）
リポジトリ: /workspace
ブランチ（測定時）: develop
HEAD: e7b4df34a62fcfe714944ccfceb68baf9c2bf99a
git log -5:
  e7b4df3 Merge pull request #443 from Cor-Incorporated/feat/dsh-launcher-keychain-session
  d9d883e fix(dsh): unset the keychain scratch variable so an exported caller `s` cannot carry the session
  9ab0d3b fix(dsh): never pass BW_SESSION to a bare dsh; tests assert the child really starts
  43df02f fix(dsh): resolve bw-secrets by install path and fall back when the session is unusable
  17fdaf4 feat(dsh): web UI gets DEEPSEEK_API_KEY from Bitwarden without a shell session
git status --porcelain: 空
git worktree list: /workspace e7b4df3 [develop]
open PR: #418 draft, head fix/h17-p1a-vocab, base develop
  files: hooks/README.md, hooks/lib/aidd-cc-adapter.sh, hooks/lib/aidd_cc.py,
         hooks/lib/aidd_cc_controls.py, hooks/lib/aidd_cc_eval.py, hooks/lib/aidd_cc_text.py,
         rules/quality.md, tests/fixtures/h17-claim-phrases.json, tests/test-aidd-cc.sh
claude-code-skills PR #94: state MERGED, mergedAt 2026-03-23T22:26:03Z,
  title "docs: プロジェクト全体包括監査レポート 2026-03-24"
claude-code-skills issue #454: Could not resolve to an issue or pull request with the number of 454
claude-code-skills PR #454: Could not resolve to a PullRequest with the number of 454
Cor-Incorporated/aidd-governance: Could not resolve to a Repository with the name 'Cor-Incorporated/aidd-governance'
パス実在:
  MISSING /home/ubuntu/developer/m02-smart-glasses
  MISSING /home/ubuntu/Developer/m02-smart-glasses
  MISSING /home/ubuntu/developer
  MISSING /home/ubuntu/Developer
  MISSING /home/ubuntu/.claude/state/async-work
  MISSING /home/ubuntu/.claude/hooks/git-push-guard.sh
  MISSING /home/ubuntu/.claude/hooks/protect-branches.sh
  MISSING /home/ubuntu/.cursor/hooks/git-guard.sh
  MISSING /home/ubuntu/.codex/rules/default.rules
  EXISTS /workspace/hooks/git-push-guard.sh
  EXISTS /workspace/hooks/protect-branches.sh
  EXISTS /workspace/tests/test-cross-tool-force-matrix.sh
  EXISTS /workspace/skills/handover/common-clauses.md（8090 bytes）
結論: この VM に製品チェックアウトとフック配備が無い。ここで製品実装を始めることは不可能。実行場所はゲート Mac。Mac で同じ確認を出すまで編集に入らない。
```

5. **人間ゲート列挙:** 準備（読み取り、worktree 作成、単体テスト、ゲート内のローカル編集、SHA の計算）は可。本番系の迂回経路を新設することは不可。迂回が要ると判断したときは停止し、権限・巻き戻しの 1 枚を寺田の合意として待つ。ゲート一覧は「判断待ち」節。
6. **反証可能な完了条件:** 報告ファイルに Evidence が無く、送信件数の 0 記録が無く、対象パスの `ls` または `test -e` の生出力が無いとき、この委任は完了ではない。完了と書いてあっても、その 3 点が欠けていれば偽である。
7. **事前スパイク回答欄:** 新しいフレームワークと新しい外部 API は、この期間に採用しない。note API、SNS API、メール API、本番デプロイ API、クラスタ再起動 API は呼ばない。org の allowlist は未確認である（aidd-governance がこの VM から解決できない）。未確認の org 設定を推測で書かない。「確認せず採用する」は、この 7 欄では使わない。
8. **完了条件の検査:** 報告ファイルが存在しても、中身が見出しだけで Evidence が無い入力は目的未達である。テストが green でも、送信が 1 件あれば目的未達である。SHA 文字列をこの文書から再掲しただけでは照合にならない。計算コマンドの出力との比較行が要る。この 3 入力は着手前に構成できているので、完了条件は「ファイルがある」「テストが green」「SHA を書いた」に置かない。
9. **追加を提案しない:** 新しいガード、新しい hook、新しい workflow、新しい required check が必要と判断したら、実装せず提案して停止する（Issue #27 凍結）。既存ファイルの判定条件が、塞ぐべき形を塞げていない場合は修復であり、その場で塞ぐ。修復は新しいファイルを増やさない変更に限る。判定は、新しいファイル・新しい登録・新しい required check が要るなら追加（停止）、既存ファイルの判定条件だけなら修復（実施）。
10. **強制点の実測表:** この委任は git と対象製品の 2 面以上に触れる。空欄のまま製品編集に入らない。

| ツール | 強制点のパス | 入力契約 | 2026-10-29T13:36:26Z の実測（この VM） | 測定コマンド |
|---|---|---|---|---|
| Claude Code | `/home/ubuntu/.claude/hooks/git-push-guard.sh` | stdin JSON `tool_input.command` → exit≠0 で block | MISSING | `test -x "$HOME/.claude/hooks/git-push-guard.sh"; echo $?` |
| Claude Code | `/home/ubuntu/.claude/hooks/protect-branches.sh` | 同上。`git-push-guard.sh` と合成 | MISSING | `test -x "$HOME/.claude/hooks/protect-branches.sh"; echo $?` |
| Cursor | `/home/ubuntu/.cursor/hooks/git-guard.sh` | stdin `{"command":...}` → permission deny | MISSING | `test -x "$HOME/.cursor/hooks/git-guard.sh"; echo $?` |
| Codex CLI | `/home/ubuntu/.codex/rules/default.rules` | `codex execpolicy check --rules default.rules` | MISSING | `test -f "$HOME/.codex/rules/default.rules"; echo $?` |
| リポジトリ内の測定器 | `tests/test-cross-tool-force-matrix.sh` | 受領側パスが無ければ全 SKIP。SKIP の緑は均衡の証明ではない | EXISTS（この VM では受領側が MISSING なので実行しても均衡の証明にならない。未実行） | `ls tests/test-cross-tool-force-matrix.sh` |

ゲート Mac で上の 4 つの受領側パスを同じコマンドで再測定し、結果を報告に貼る。未測定の行が残っている間は製品ファイルを編集しない。測定器の正本は `tests/test-cross-tool-force-matrix.sh`（claude-code-skills）。



## 一次資料

- 寺田康佑（Cor.）の 2026-10-29 指示。抽出した要求は、期間（2026-10-29〜2026-11-01）、成果物ディレクトリ `handoffs/20261029-until-1101/` の 7 ファイル、各ファイルの必須節、直近インシデント 10 件、5 スコープ、メール / Slack / SNS 送信と merge と本番公開の禁止、Desktop コピー手順、ブランチと PR。
- `skills/handover/SKILL.md`。抽出した要求は、契約 10 欄、H8 の 7 欄、`common-clauses.md` の全文連結、one-shot 委任の禁止。
- `skills/handover/common-clauses.md`（8090 bytes）。抽出した要求は、worktree、origin 基点、無差別 `git add` の禁止、ステージ後テスト、MERGED 目視前の撤収禁止。
- `rules/delegation.md`。抽出した要求は、契約欄名、課金既定 $50、完了報告の 3 欄、`Agent-Lane` trailer。
- `hooks/aidd-turn-boundary-stop.sh` の 2026-09-28 注記。抽出した要求は、共有台帳 `~/.claude/state/async-work` の他セッション行を、無関係なセッションが resolve しないこと。実測の当事者は corsweb2024 の run と ai-cluster の nohup。
- `tests/test-cross-tool-force-matrix.sh` の冒頭。抽出した要求は、受領側パスが無い SKIP を横断均衡の証明と読まないこと。
- 2026-10-29T13:36:26Z の git / gh / `test -e` 出力（本ファイルの実現可能性チェック）。抽出した要求は、未測定のパスを確定パスとして書かないこと。

## 要求インベントリ

1. `handoffs/20261029-until-1101/` に 7 つの Markdown を置く。
2. 各ファイルに Goal、Success、5W1H、確定、未確認、判断待ち、触ってよいパス、触るなパス、並列衝突、報告ファイル名、送信禁止、11/1 に Grok へ返す条件、失敗例と再発防止を置く。
3. 直近インシデント 10 件を、単体で開く各ファイルに置く。
4. スコープは ai-cluster（Tunnel / 台帳 / 分散推論、破壊的再起動は寺田確認）、smart-glasses（コードと文書、実機テスト禁止、パス `~/developer/m02-smart-glasses`）、grift CLI、corsweb2024 と griftai の CMS・記事（公開と main は寺田の後）、yomiyasu / cor-voice / cor-voice-gate の他ツール強制適用と PDCA 精度である。
5. メール、Slack、SNS、merge、本番公開をしない。
6. 報告ファイル名は `Claude_Code報告_20261029_<topic>.md`。Desktop の依頼名は `~/Desktop/Claude_Code依頼_20261029_<topic>.md`。
7. 共通条項を全文連結する。要約しない。
8. 契約 10 欄と H8 7 欄を空にしない。
9. 11/1 の返却条件を書く。返却の実行者は寺田。Claude Code は Grok へ送らない。
10. ブランチ `cursor/handoff-until-1101-6413` にコミットし、PR を develop 向けに開く。merge はしない。

## 突合表

| 要求 | 受入基準 | この PR 時点の証跡 | 未検証の限界 |
|---|---|---|---|
| 7 ファイル | `ls handoffs/20261029-until-1101` が 7 件 | 生成スクリプトが 7 パスへ書き、検証で件数を見る | ゲート Mac の Desktop へは未コピー |
| 必須節 | 各ファイルに指定見出しがある | 生成後の見出し検査 | 検査コマンドの出力は PR の作業ログ。Mac 側の再検査は未実施 |
| インシデント 10 件 | item20、item19、note-edit-safe、eyecatch、item21 SHA、BLOCKED_HUMAN、n083decbc281b、SUPERSEDE、Qiita、#94、#454 が各ファイルにある | 文字列検査 | 台帳 item19/20/21 の原本パスは未確認 |
| 送信禁止 | 各ファイルの送信禁止節にメール、Slack、SNS、merge、本番公開がある | 文字列検査 | 将来の Claude セッションが守るかは未検証 |
| 共通条項 | 各ファイル内の連結バイト列が `skills/handover/common-clauses.md` と一致 | バイト比較 | 正本を後で直しても、書き済みブリーフは自動更新されない。条項変更は正本だけを直し、次のブリーフで連結し直す |
| 製品実装 | パス確認の後に継続作業だけ進む | この VM のパスは MISSING。実装 diff は 0 | Mac 上の継続作業の中身は未見 |
| PR | develop 向け PR が開いている | PR 作成後に URL が付く | merge は寺田。この委任は merge しない |

## 標準質問

- ユーザー像: 指示者は寺田康佑（Cor.）。実行者はゲート Mac の Claude Code Desktop。検収者は寺田。Grok は 11/1 の返却先であり、この期間の実装者ではない。
- 審美: 報告は実測コマンドと生出力を先に書く。完了を表す形容詞は Evidence 行の後に置く。
- LLM 挙動境界: パス、SHA の入力、凍結番号の所在を、それらしい近縁へ補完しない。未確認は未確認と書く。
- 安全境界: 実機、デバイス実測、破壊的再起動、本番公開、メール、Slack、SNS は人間ゲートの向こうにある。ゲートの手前で行うのは、読み取り、worktree、単体テスト、ローカル編集、SHA 計算である。
- セキュリティ境界: 認証情報、トークン、cookie、セッション鍵を報告、コミット、PR 本文に書かない。`~/.claude/state/` へ直接書き込まない。

## 北極星

期間中のメール、Slack、SNS、merge、本番公開が 0 件であり、2026-11-01 の停止時に各レーンの報告ファイルが Desktop にあり、各報告が Evidence 行を持つこと。測定時点は、レーンの着手時と 2026-11-01 の停止時。変更行数とセッション時間は完了の根拠にしない。

## 反証軸

F2 の事故入力は次である。note 更新として新しい key の下書きを作る。全文 HTML を note に貼る。SHA 計算結果が `19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a` と等しい行が報告に無い状態で corsweb または griftai の記事ファイルを保存する。`BLOCKED_HUMAN` のまま TimeSync の E2E を起動する。`#454` を、所在未確認のまま別リポジトリで close する。この入力が 1 つでも実行履歴に現れたら、この委任は失敗である。再現入力は、シェル履歴、`git log`、送信 API の呼び出しログから同じ操作を探すことである。

## 撤収

委任ウィンドウ（2026-10-29〜2026-11-01、Asia/Tokyo）の状態は active である。この handoff 包の回収先はブランチ `cursor/handoff-until-1101-6413` の PR であり、状態は preserve である。各レーンの実装成果の回収先は、そのレーンが切った worktree のブランチと、merge していない PR である。worktree とブランチを消す前に `gh pr view <PR> --json state -q .state` で MERGED を目視する。未マージの成果を消さない。報告ファイルは `~/Desktop/Claude_Code報告_20261029_<topic>.md` に preserve する。Archive による retire はしない。寺田の SUPERSEDE の後も、旧依頼ファイルは Desktop に残す。

## 識別子境界

触ってよい識別子は、上表の依頼ファイル名と報告ファイル名、note の既存 key `n083decbc281b` を原稿中で引用すること、item21 の照合値 `19b743377f320e675907c1b5656c114e1f8efca991b489447b5f079a15275f8a` を比較対象に使うこと、である。

触ってはいけない識別子は、新しい note key、凍結番号 `#94` と `#454` を所在未確認のまま close または reopen すること、claude-code-skills の MERGED PR `#94` を凍結解除の操作先にすること、draft PR `#418` のブランチ `fix/h17-p1a-vocab` へコミットすること、である。


## タスク

1. corsweb2024 と griftai の toplevel をそれぞれ `git rev-parse --show-toplevel` で報告する。片方でも見つからなければ、見つかった側も含めて編集せず停止する（片側だけ進めると SHA の「込み」が崩れる）。
2. item21 のハッシュ手順をリポジトリ内で探す。見つからなければ編集 0 で停止し、判断待ちに手順不明と書く。
3. 手順のコマンドを実行し、出力と `{SHA}` の比較結果を報告に書く。一致が yes のときだけ、両リポジトリの継続対象（status と open PR）を編集する。
4. 記事に定数を書くときは引用にとどめる。業界例を足すときは ROS2 を使う。note API は呼ばない。


以下は `skills/handover/common-clauses.md` の全文である。要約、抜粋、言い換えをしていない。レーン固有の範囲は、この節の後の「所有範囲」にある。

<!-- COMMON-CLAUSES-BEGIN -->
<!--
  ブリーフ共通条項 — 全レーンへ機械的に連結する正本.

  Issue: Cor-Incorporated/aidd-governance#91 項目 3

  起点 (#91 Who 節):
    監督は 2026-08-26 夜、Phase B の 4 Issue を並列レーンへ委任した。
    別レーン（#2015）のブリーフには「store は再実装しない」と書いていたが、
    **同じ日に、同じ注意書きを片方のブリーフだけ落とした。**
    落とした側（#2007 / feat/l-s6-api）が develop 既存の 4 ファイルを独立に
    再実装し、add/add 競合 4 件・650 行 対 290 行でブランチ側が全損した。

  2026-09-03 の追補:
    共有チェックアウトでの事故が同日 2 件（+ lane-delflag 報告分で計 3 件）。
    監督は毎回「worktree を使え」「共有チェックアウトを切り替えるな」を
    手書きで写しており、**写し忘れが事故 1 の遠因**だった。

  なぜファイルに切り出すのか:
    手書きで各ブリーフへ注意書きを写すと、適用が不揃いになる。
    不揃いは「書いた/書かない」の記憶に依存し、レーン数に比例して漏れる。
    1 ファイルに置いて全ブリーフへ**機械的に連結**すれば、漏れは構造的に消える。

  使い方:
    handover skill の手順 5 で、生成する文書へ本ファイルの中身をそのまま
    挿入する。**要約・抜粋・言い換えをしない**（それをした瞬間に不揃いが戻る）。
    レーン固有の事情は本文ではなく、各ブリーフの「所有範囲」欄に書く。

  変更するとき:
    本ファイルだけを直す。ブリーフ側へ写した文言を個別に直さない。
    tests/test-handover-common-clauses.sh が SKILL.md との結線を機械照合する。
-->

## 共通条項（全レーン共通。ブリーフごとに書き換えない）

### 作業環境 — worktree を必ず切る

- **共有チェックアウトで作業しない。** 必ず自分の worktree を切る:
  ```
  git -C <repo> worktree add <repo>/.worktrees/<agent>/<slug> -b <branch> origin/<base>
  ```
- **共有チェックアウトのブランチを切り替えない**（`git checkout` / `git switch` / `git checkout -`）。
  他レーンが同じツリーで作業している。
- **共有チェックアウトで無差別ステージングをしない**（`git add -A` / `git add .` / `git commit -a`）。
  他レーンの worktree ごと巻き込む。実測: ccs では 51 個の embedded git repository を stage しようとする。
- 上記 3 点は `hooks/lane-launch-gate.sh` が block する。**block されたら迂回せず、worktree を切る。**

### 基点 — origin から切り直す

- worktree の起点は **必ず `origin/<base>` を明示**する。省略すると現在の HEAD が使われ、
  基点が静かに古くなる（worktree は「作った時の基点」を保持し、再利用しても更新されない）。
- 起点が古いと、その間に着地した他レーンの成果が見えない。
  **同じ領域を独立に再実装すると add/add 競合になり、成熟度の低い側が破棄される。**

### 重複実装の回避

- **既存の domain / store / service を再実装しない。** 着手前に対象領域が既に実装済みでないか確認する。
- 追加は**新規ファイルへ分離**する。既存ファイルへの追加は interface 宣言に留める。
- 触る予定のパスを `LANE_PATHS`（改行区切り）で宣言すると、稼働中の他レーンとの重複が警告される。
  警告に `未merge` が付いていれば**調整**が要る。`陳腐化の疑い` が付いていれば**掃除**が要る。

### 検証 — テストは `git add` の後に回す

- **全 suite の実行は `git add` の後**にすること。多くの lint / 検査は `git ls-files`
  で走査対象を決めるため、**未追跡の新規ファイルは検査されない**。ステージ前に回すと
  **ローカル緑 / CI 赤**になる。

  ```
  git add <自分の worktree 内のパス>   # 共有チェックアウトでは add -A を使わない
  for f in tests/test-*.sh; do bash "$f" || echo "FAILED: $f"; done
  ```

- 2026-09-03 に**同じ形を 2 人が別々に踏んだ**（ccs #363 と #372）。どちらも
  「実行時点で未追跡 → `git ls-files` に出ない → ローカル緑 / CI 赤」だった。
  **CI は最後の確認であって最初の確認ではない**（#90）。

### 撤収 — マージを確認してから消す

- **worktree とブランチを消す前に、その成果が着地したことを確認する。**
  確認せずに掃除すると、未マージの成果が消える。

  ```
  gh pr view <PR> --json state -q .state     # MERGED を目視してから消す
  git worktree remove <path> && git branch -D <branch>
  ```

- **`;` で繋がない。** `gh pr merge ... ; git worktree remove ...` は merge が
  拒否されても掃除が走る。2026-09-03 に実際にこれで削除し、復元して reopen する
  手戻りが出た。`&&` で繋ぐか、state を確認してから分岐する。

#### 陳腐化した worktree を機械的に掃除する基準

3 条件を**すべて**満たすものだけを消す。1 つでも欠けたら残す。

1. `git merge-base --is-ancestor HEAD origin/<base>` が真、かつ `origin/<base>..HEAD` が 0
2. 最終コミットから **7 日以上**（H11 / repo-clean）
3. 未コミットのファイルのうち **`origin/<base>` に存在しないもの**が 0 件
   — ただし**再生成可能な生成物は数えない**

**再生成可能として除外してよいもの（実測で現れたものだけを列挙する。推測で足さない）**

| パターン | 根拠 |
|---|---|
| `**/__pycache__/**`, `*.pyc` | Python バイトコード。ソースから再生成される |

**判断がつかないものは残す側へ倒す。** 2026-09-03 の実測では、未コミットを持つ 7 本に
`origin/<base>` に無いファイルが 39 件あり、内訳は `.sample` 14 / `.md` 7 /
拡張子なし 5 / `.stderr` 4 / `.jsonl` 4 / `.tsv` 2 / `.pyc` 1 / `.log` 1 だった。
このうち再生成可能と**言い切れた**のは `.pyc` 1 件だけである。
`.sample`（`git init` が置く hook テンプレート）も再生成可能だが、
それを除外しても結論が変わる worktree は 1 本も無かったので**列挙しない**
（結論を変えない除外は、リストを太らせて誤除外の面だけ広げる）。

`.stderr` / `.jsonl` / `.log` / `.tsv` / `.md` は**実測の生ログ**であり、
`quality.md` が完了報告に要求している証跡そのもの。**消すと再取得できない。**

**基準を曲げて 1 本を裁量で消さないこと。** 消すべきものが残るなら、
裁量ではなく**この表に行を足して**基準ごと直す。1 本を裁量で消せば、
次は「これも似たようなものだから」で境界が動く。

### 報告

- 完了報告には実成果物 1 点（実プロンプト / 生ログパス / 実スクショ / DB 実測値）と、
  機械添付（ID・実行時刻・件数）を含める。
- 断定（「完了」「verified」「根因確定」）には証跡トレーラーを付ける:
  `Evidence: <実行コマンド> | <生出力の要点 or ログパス> | <実行時刻>`
- 撤収 3 欄を書く: 回収コミット SHA / 削除した worktree・ブランチ / 残す判断待ち在庫（理由つき）。

### 禁止

- 認証情報を文書・コミット・PR 本文に含めない。
- 状態ファイルへの直接書き込みを避ける。
- one-shot 委任（検収往復なし）をしない。
- **失敗を握り潰さない。** `2>/dev/null ||` や `|| true` で分岐生成・checkout の失敗を隠すと、
  後続の add/commit が意図しないブランチに載る（2026-09-03 の事故 1 はこの形）。

<!-- COMMON-CLAUSES-END -->


## 所有範囲

所有するのは、SHA 一致後の corsweb2024 と griftai のローカル CMS・記事原稿と、この topic の報告ファイルである。公開系の認証情報は所有範囲に入らない。

- 触ってよい: 上の「触ってよいパス」節の箇条書き。参照語だけでパスを増やさない。
- 触ってはいけない: 上の「触るなパス」節の箇条書き。
- 禁止事項枠: 「送信禁止」節。共通条項の禁止（認証情報、状態ファイルへの直接書き込み、one-shot、失敗の握り潰し）も有効である。

## 完了時の報告形式

- ファイル名: `Claude_Code報告_20261029_corsweb-griftai-cms-articles.md`
- Evidence: `<コマンド>` | `<生出力の要点またはログパス>` | `<実行時刻>`
- 回収コミット SHA / 残している worktree とブランチ / 判断待ち在庫（理由つき）
- 送信件数は 0 を、チャネルごとに書く。
