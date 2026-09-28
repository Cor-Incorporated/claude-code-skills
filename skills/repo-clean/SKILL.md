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
- 入った日は「基準ブランチに入ったコミットの日付」で、origin/develop が動いた日ではない。fast-forward や、
  ローカルで作ったマージを後から push した場合は、実際より古く見える
- ローカル削除は `git branch -d` のみ（`-D` 強制削除は使わない）→ 未マージなら git 側が拒否する
- `--apply --remote` はリモート → ローカルの順に消す。upstream が残っていると、基準ブランチに
  入っていても upstream より先に進んだブランチを `git branch -d` が拒否するため
- リモートは open PR が無いことを gh で確かめてから消す。確かめられなければ（gh が無い・未認証など）
  `SKIP (open PR の有無を確かめられない)` として残す。消すときは `--force-with-lease` で、fetch した
  先端から動いていないことを確かめる
- `origin/HEAD` は基準ブランチの別名なので、リモートの一覧に出さない
- repo のパスへ移動できなければ何もせず終了する（今いるディレクトリを掃除しない）
- 渡したパスの worktree と、呼び出し元がいる worktree は消さない（`SKIP (この実行が使っている worktree)`）
- 呼び出し元の `GIT_DIR`・`GIT_WORK_TREE` などは引き継がない
- dry-run も `git fetch --prune` で origin の追跡ブランチを更新する（`git worktree prune` は `--apply` のときだけ）
- `--apply` は計画を作り直す。承認した dry-run の直後に実行する（日付をまたぐと、7 日を越えた分が候補に加わりうる）
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
