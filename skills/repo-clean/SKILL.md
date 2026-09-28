---
name: repo-clean
description: "Safely clean up merged worktrees, local branches, and remote branches in a repo using a dry-run-first janitor script with protected-branch guards. Invoke with: /repo-clean [repoパス]. Use when the user says 'worktree整理して', 'ブランチ掃除', '不要なブランチを消して', 'リポジトリをきれいに', or before starting a new wave. Do NOT use for: deleting unmerged work (never), issue cleanup (separate gh triage), or dead-code removal (use /refactor-clean)."
---

# Repo Clean — worktree・ブランチの安全な掃除

「メインとデベロップ以外のマージ済み worktree・ブランチを消して」という定期依頼を、dry-run → 承認 → 実行の3段階で安全に自動化する。

## 手順

1. **dry-run（何も消さない。origin の追跡ブランチだけは fetch で更新される）を実行して計画を提示**:
   ```bash
   bash ~/.claude/scripts/repo-janitor.sh <repoパス>
   ```
   出力: worktree / ローカルブランチ / リモートブランチ別の「削除候補・SKIP理由つき一覧」。
   基準ブランチに入ってから 7 日未満のものは `KEEP (entered develop 2026-09-25, < 7 days)` のように
   入った日つきで残る（rules/git-workflow.md「機械掃除は マージ済み + 7 日 限定」）
2. **計画をユーザーに提示して承認を得る**（削除は不可逆。ここは省略禁止）:
   - 削除候補の件数と、SKIP された dirty worktree / unmerged branch を明示する
   - dirty worktree に未保存の作業が残っていそうな場合は中身を確認して報告する
3. 承認後に実行:
   ```bash
   bash ~/.claude/scripts/repo-janitor.sh <repoパス> --apply           # ローカルのみ
   bash ~/.claude/scripts/repo-janitor.sh <repoパス> --apply --remote  # リモート込み
   ```
4. 実行後の検証:
   ```bash
   git -C <repo> worktree list && git -C <repo> branch -a | head -30
   ```
   削除件数・残存一覧を報告する。FAILED には git の拒否理由が 1 行で付くので、それを添えて報告する。

## スクリプトの安全装置（前提として把握しておく）

- 保護ブランチ（main/master/develop/stg/staging/production）は worktree・ローカル・リモートすべてで対象外
- 基準ブランチに入ってから `MIN_AGE_DAYS`（7）日未満の worktree・ローカル・リモートは消さない。
  入った日は、基準ブランチの first-parent を二分探索して tip を含む最初のコミットの日付で測る
  （tip の最終コミット日ではない）。日数は tests/test-pairs-link.sh の pair19 が規則と照合する
- worktree と、自分のコミットが無いブランチ（先端が基準ブランチの first-parent 上にある。develop から
  作ったばかりのブランチなど）は、作られてから 7 日未満なら消さない。作られた日は reflog の最も古い
  記録で測り、分からなければ消さない（`KEEP (worktree created …)` / `KEEP (no own commits, …)`）
- 入った日は「基準ブランチに入ったコミットの日付」。自分のコミットが無い先端（fast-forward で入った
  ものを含む）は、コミットの日付では分からないので、手元の `origin/<base>` の reflog で初めてそれを
  含んだ日も 7 日以上前であることを求める（`KEEP (no own commits, first seen in …)`）。ローカルで
  作ったマージを後から push した場合は、実際より古く見える（既知の制限）
- ignore されたファイルがある worktree は、handover の撤収基準 3 が「再生成可能」と列挙したもの
  （`**/__pycache__/**`, `*.pyc`）以外があれば消さない（`git worktree remove` は ignore されたファイルも
  一緒に消す）。列挙は `skills/handover/common-clauses.md` の表が正で、pair19 が janitor と照合する
- ローカル削除は `git branch -d` のみ（`-D` 強制削除は使わない）→ 未マージなら git 側が拒否する
- `--apply --remote` はリモート → ローカルの順に消す。upstream が残っていると、基準ブランチに
  入っていても upstream より先に進んだブランチを `git branch -d` が拒否するため
- リモートは open PR が無いことを gh で確かめてから消す。origin が fork なら祖先のリポジトリ（親、fork の
  fork なら親の親…、5 段まで）の PR も見る。確かめられなければ（gh が無い・未認証・祖先をたどり切れない・
  origin が GitHub の URL でないなど）`SKIP (open PR の有無を確かめられない)` として残す。そのブランチを
  base にする open PR（stacked PR）があるか、それを確かめられなければ残す（base を消すとその PR は閉じる）
- 残す worktree（main worktree を含む）で checkout 中のブランチは、ローカルもリモートも消さない
  （`SKIP (残す worktree で checkout 中)`。同じブランチを 2 つの worktree で checkout していて片方だけ消す場合も
  残す）。`--apply` は消す直前に、今も checkout 中でないことを確かめ直す（`SKIP (worktree でまだ checkout 中)`）
- リモートを消すときは `refs/heads/<branch>` を指定し（短い名前だと、ブランチが先に消えていれば同じ名前の
  タグを消し、両方あれば拒否される）、`--force-with-lease` で fetch した先端から動いていないことを確かめる
- 消すと失われる作業がある worktree は消さない。`git worktree remove` は次のものを見落として消すため、
  その手前で止める:
  - `status.showUntrackedFiles=no` で隠れる未追跡ファイル（`--untracked-files=all` で数える）
  - `submodule.<name>.ignore` で隠れる submodule の変更（`--ignore-submodules=none` で数える）
  - assume-unchanged / skip-worktree の付いたファイル（`SKIP (変更が git status に出ないファイルがある …)`）
  - lossy な clean filter（nbstripout など）を通すと HEAD と同じに見えるが、作業ツリーの中身は index と
    違うファイル（`SKIP (clean filter で git status に出ない中身がある …)`。Git LFS は作業ツリーと index が
    常に違うので除く）

  `--apply` は消す直前に同じ確認をやり直し、計画の後に変わっていれば消さない（`SKIP (計画の後に変わった: …)`）。
  ほかにも git status から中身を隠す仕組みはありうる（上の 4 つで網羅したとは言えない）
- ロックされた worktree は消さない（`SKIP (locked)`。`git worktree remove` も拒否する）
- 基準ブランチは `refs/remotes/origin/<base>` の完全な名前で git に渡す（`origin/develop` という名前の
  ローカルブランチがあっても、そちらをマージ済みの判定に使わない）
- fetch に失敗したらリモートは消さない（`SKIP (fetch に失敗したので消さない)`）。基準ブランチは fetch の
  後で選ぶ
- `origin/HEAD` は基準ブランチの別名なので、リモートの一覧に出さない
- repo のパスへ移動できなければ何もせず終了する（今いるディレクトリを掃除しない）
- 渡したパスの worktree と、呼び出し元がいる worktree は消さない（`SKIP (この実行が使っている worktree)`）
- 呼び出し元の `GIT_DIR`・`GIT_WORK_TREE` などは引き継がない
- dry-run も `git fetch --prune` で origin の追跡ブランチを更新する
- ディレクトリが見つからない worktree の管理情報は、最後に使われてから（その worktree の index が書かれて
  から）7 日を過ぎたものだけ `git worktree prune --expire` で片付ける。外付けディスクを外しているだけの
  worktree を切り離さないため。ただし index の無い worktree（`git worktree add --no-checkout` など）は、git が
  日数を見ずに片付ける。dry-run は `- PRUNE 候補:`、`--apply` は `- PRUNED:` として表示する
- 計画は prune の前の worktree の一覧で立てる。片付けた worktree のブランチは、その回は
  `SKIP (checked out in worktree)` のまま残り、次の実行の dry-run に出てから消える（承認していないものを
  `--apply` が消さない）
- `--apply` は計画を作り直す。承認した dry-run の直後に実行する（日付をまたぐと、7 日を越えた分が候補に加わりうる）。
  計画と実行の差は、日付と、計画の後に worktree で起きた変化だけで、後者は消さない側にだけ倒れる
- dirty な worktree・現在 checkout 中のブランチは自動スキップ
- リモート削除は「基準ブランチにマージ済み + open PR なし」の二重チェック、かつ `--remote` 明示時のみ

## 注意・禁止事項

- **dry-run を飛ばして --apply を実行しない。** ユーザー承認前の削除実行は禁止。
- SKIP (dirty) された worktree を「邪魔だから」と `--force` で消さない。中身の確認と退避が先。
- `git push origin --delete` は復元に手間がかかる。リモート削除は毎回明示承認を取る。
- スクリプトが FAILED を返したブランチを `-D` で強制削除しない（未マージの可能性）。
- squash マージの枝と detached の worktree は `KEEP (unmerged)` と出る。消すなら、`git cherry origin/develop <branch>`
  がすべて `-` か、tip が PR の headRefOid と一致する（GitHub の `refs/pull/N/head` に残る）ことを確かめてから、
  ユーザーの承認を得て個別に扱う
- hook `protect-branches.sh` が保護ブランチ操作をブロックする環境である前提。ブロックされたら従う。
