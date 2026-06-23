# GitHub mergeable と local gate の切り分け runbook

## 目的

GitHub の `mergeable` / `mergeStateStatus` と、Claude Code の local hook gate は別の判定です。

- GitHub mergeable: GitHub 上の base/head、branch protection、ruleset、CI、conflict の状態
- local gate: このリポジトリの hook が保持する review state、pending comment hash、ローカル base snapshot の鮮度

`mergeable=CLEAN` でも local gate が止める場合があります。その場合は GitHub blocker ではなく local gate blocker として扱います。

## まず GitHub 側を確認する

```bash
PR=123
REPO=Cor-Incorporated/claude-code-skills

gh pr view "$PR" -R "$REPO" \
  --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,baseRefName,headRefOid

gh api "repos/$REPO/pulls/$PR" \
  --jq '{state, mergeable, mergeable_state, base_ref: .base.ref, base_sha: .base.sha, head_sha: .head.sha}'
```

ここで conflict、required check failure、review requirement が出る場合は GitHub 側の blocker です。

## local gate 側を確認する

```bash
PR=123
REPO=Cor-Incorporated/claude-code-skills

git fetch origin develop
git rev-parse origin/develop
BASE_REF=$(gh api "repos/$REPO/pulls/$PR" --jq '.base.ref')
gh api "repos/$REPO/git/ref/heads/$BASE_REF" --jq '.object.sha'

jq '.' .claude/state/pending-review-comments.json 2>/dev/null || true
jq '.' .claude/state/review-status.json 2>/dev/null || true
jq '.' .claude/state/pr-review-lock.json 2>/dev/null || true
```

`origin/develop` と GitHub の `.base.sha` が一致しない場合、local gate は `LOCAL_GATE_STALE_BASE` としてブロックします。GitHub 上で clean でも、local gate が古い base snapshot で tier/review 判定をしてはいけないためです。

## pending-review-comments.json の扱い

- 現在の PR と `pr` / `head_sha` / `comment_set_hash` が一致する場合だけ、Pass B の判定に使います。
- 現在の PR だが `head_sha` または `comment_set_hash` が古い場合は `LOCAL_GATE_STALE_REVIEW_STATE` としてブロックします。
- 別 PR の pending state は現在 PR の承認にも hard block にも使いません。
- GitHub が closed/merged と返す pending state は安全に削除します。

手動 cleanup:

```bash
GATE_MODE=CLEANUP bash hooks/pr-ci-review-gate.sh
```

最新 state を取り直す:

```bash
gh pr checks "$PR" -R "$REPO"
bash ~/.claude/scripts/verify-pr-review.sh "$PR"
```

## merge 前の local gate 発火確認

```bash
PR=123
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge %s --merge --repo Cor-Incorporated/claude-code-skills"}}\n' "$PR" \
  | GATE_MODE=PRE_MERGE bash hooks/pr-ci-review-gate.sh
```

`LOCAL_GATE_STALE_BASE` または `LOCAL_GATE_STALE_REVIEW_STATE` が出た場合は、GitHub mergeable ではなく local gate の復旧として扱います。

## setup / drift 確認

hook を変更した後は repo state と `~/.claude` の deploy state を分けて確認します。

```bash
bash setup.sh

cmp hooks/pr-ci-review-gate.sh ~/.claude/hooks/pr-ci-review-gate.sh
cmp hooks/gate-modes/pre-merge.sh ~/.claude/hooks/gate-modes/pre-merge.sh
cmp hooks/enforce-review-reading.sh ~/.claude/hooks/enforce-review-reading.sh
cmp settings.json ~/.claude/settings.json
```

UAT 証跡 hook は別件の安全策です。`hooks/enforce-uat-evidence.sh` と `tests/test-uat-evidence-hook.sh` はこの gate 復旧と独立に維持してください。
