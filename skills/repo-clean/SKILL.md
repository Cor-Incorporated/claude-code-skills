---
name: repo-clean
description: "Safely clean up merged worktrees, local branches, and remote branches in a repo using a dry-run-first janitor script with protected-branch guards. Invoke with: /repo-clean [repoパス]. Use when the user says 'worktree整理して', 'ブランチ掃除', '不要なブランチを消して', 'リポジトリをきれいに', or before starting a new wave. Do NOT use for: deleting unmerged work (never), issue cleanup (separate gh triage), or dead-code removal (use /refactor-clean)."
---

# Repo Clean — worktree・ブランチの安全な掃除

「メインとデベロップ以外のマージ済み worktree・ブランチを消して」という定期依頼を、dry-run → 承認 → 実行の3段階で安全に自動化する。

## 手順

1. **dry-run（read-only）を実行して計画を提示**:
   ```bash
   bash ~/.claude/scripts/repo-janitor.sh <repoパス>
   ```
   出力: worktree / ローカルブランチ / リモートブランチ別の「削除候補・SKIP理由つき一覧」
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
   削除件数・残存一覧を報告する。FAILED があれば理由（未マージ扱い等）を調べて報告。

## スクリプトの安全装置（前提として把握しておく）

- 保護ブランチ（main/master/develop/stg/staging/production）は worktree・ローカル・リモートすべてで対象外
- ローカル削除は `git branch -d` のみ（`-D` 強制削除は使わない）→ 未マージなら git 側が拒否する
- dirty な worktree・現在 checkout 中のブランチは自動スキップ
- リモート削除は「基準ブランチにマージ済み + open PR なし」の二重チェック、かつ `--remote` 明示時のみ

## 注意・禁止事項

- **dry-run を飛ばして --apply を実行しない。** ユーザー承認前の削除実行は禁止。
- SKIP (dirty) された worktree を「邪魔だから」と `--force` で消さない。中身の確認と退避が先。
- `git push origin --delete` は復元に手間がかかる。リモート削除は毎回明示承認を取る。
- スクリプトが FAILED を返したブランチを `-D` で強制削除しない（未マージの可能性）。
- hook `protect-branches.sh` が保護ブランチ操作をブロックする環境である前提。ブロックされたら従う。
