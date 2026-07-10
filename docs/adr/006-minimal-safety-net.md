# ADR-006: Minimal Safety Net — Hook Reduction

## Status
Accepted

## Date
2026-07-10

## Context

The hook graph grew organically from 18 hooks (pre-Epic #130) to a peak of
64 shell scripts + 7 `gate-modes/` modules + 1 Python helper (72 registered
commands, 29 of which were hard PreToolUse blocks: merge gates, factcheck
gates, context-budget gates, Codex delegation gates, state-file tampering
guards, and more). Each gate was added in direct response to a real
incident — state-file tampering to bypass review, phantom completions
(Issue #174), review bypass on merge — and each was individually
justifiable at the time it was added.

By 2026-Q2/Q3 the cumulative false-positive cost of this stack started
exceeding the risk it mitigated. During the planning session for this very
change, live gates blocked plain documentation/test work at least 6 times,
including:

- `git-push-guard.sh` misfiring on a Bash `echo` command that merely
  contained a test string resembling a force-push.
- `pr-ci-review-gate.sh` (PRE_CREATE mode) blocking a plan-file write that
  had nothing to do with PR creation.
- `block-manual-merge-ops.sh` blocking a read-only revision comparison
  (`git diff`/`git log` between refs) because it pattern-matched on
  merge-like tokens.

Models have also matured substantially since the gates were designed
(Claude 4.5/5-era instruction following and self-verification are
materially better than the 2026-Q1 baseline the original gate stack was
built for). The marginal safety value of many deterministic regex gates is
now lower than the throughput they cost.

## Decision

Adopt a **minimal safety net**: hard PreToolUse blocks are reserved
**only** for destructive/irreversible operations. Everything else —
merge-readiness, review completeness, factchecking, context budgeting,
Codex call cadence, architecture-layer conformance — is delegated to
GitHub branch protection, the PR review workflow, and agent judgement
(guided by `rules/*.md`), not to local deterministic hooks.

### Keep-list

**Blocking (4 — PreToolUse hard-block, exit 2):**

| Hook | Blocks |
|------|--------|
| `git-push-guard.sh` | Force-push and direct push to protected branches (`main`, `develop`) |
| `protect-branches.sh` | Deletion of protected branches |
| `block-local-hooks-write.sh` | `settings.local.json` overriding the global `hooks` section |
| `validate-no-local-hooks.sh` | (SessionStart) warns/blocks if such an override already exists |

**Advisory / infra (13 — informational, never exit 2):**

`enforce-hook-deploy-integrity.sh`, `enforce-hook-deploy-after-merge.sh`,
`auto-init-permissions.sh`, `auto-update-plugins.sh`,
`validate-provider-env.sh`, `enforce-branch-workflow.sh`,
`verify-agent-output.sh`, `auto-commit-worktree-changes.sh`,
`post-deploy-verify.sh`, `post-lint-format.sh`, `notify-agent-failure.sh`,
`tool-failure-recovery.sh`, `pre-compact-context-save.sh`.

**Delete everything else.** All remaining hooks (56 scripts + the entire
`gate-modes/` directory) are retired into `hooks/_unused/` for
traceability, unregistered from `settings.json`, and no longer copied by
`setup.sh`. This includes the full review/CI merge-gate stack
(`pr-ci-review-gate.sh` + `gate-modes/*`, `block-merge-without-ci.sh`,
`block-merge-without-review.sh`, `pr-merge-claude-review-gate.sh`,
`enforce-review-reading.sh`, `inject-claude-review-*`), the factcheck
suite, the context-budget suite, the Codex single-call gate
(`codex-task-gate.sh`/`codex-task-release.sh`), `block-codex-mcp.sh`,
`enforce-codex-delegation.sh`/`enforce-codex-for-impl.sh`, the state-file
tampering pair, `protect-linter-config.sh`, `block-version-downgrade.sh`,
`enforce-architecture-layers.sh`, `enforce-git-freshness.sh`,
`enforce-uat-evidence.sh`, `stop-test-gate.sh`, `task-completion-gate.sh`,
`block-subagent-github-write.sh`, `enforce-develop-base.sh`,
`enforce-soak-time.sh`, `enforce-follow-up-limit.sh`,
`enforce-post-merge-validation.sh`, the `record-*-review` pair,
`verify-test-falsifiability.sh`, `audit-docker-build-args.sh`,
`block-local-permissions-write.sh`, `post-merge-close-issues.sh`,
`post-pr-create-review-trigger.sh`, and the rest of `hooks/_unused/`.

### Companion tooling changes

- `scripts/`: the 5 review-pipeline helper scripts
  (`check-pr-reviews.sh`, `classify-review-state.sh`,
  `review-comment-set-hash.sh`, `review-evidence-status.sh`,
  `verify-pr-review.sh`) move to `scripts/_unused/`.
  `codex-parallel.sh` / `codex-orchestrate.sh` remain as optional,
  user-invoked utilities — they are no longer gated by
  `codex-task-gate.sh`.
- `tests/`: 47+ suites covering retired hooks move to `tests/_unused/`;
  10 suites covering the surviving 4 blocking hooks remain and stay green.
- `rules/*.md` are rewritten from gate-language ("hook X blocks this") to
  guidance language ("follow this practice"; enforcement now lives in
  GitHub branch protection and human/agent review discipline).

### Cross-tool consistency

The same minimal-safety-net policy is applied in parallel, outside this
repo's `hooks/`, to keep every environment the user works in consistent:

- **opencode fork** (`packages/guardrails`): reduced to the equivalent
  minimal blocking set.
- **Cursor** (`~/.cursor`): `git-guard.sh` kept; `uat-evidence-guard`
  removed.
- **Codex CLI** (`~/.codex` execpolicy): force-push and protected-branch
  push stay forbidden; the worktree-add ban and `uat-evidence-guard` are
  removed.

## Alternatives

| Option | Rejection Reason |
|--------|-----------------|
| Keep all hooks, make them warn-only instead of removing | Still costs read/parse time and context on every tool call; false-positive *noise* remains even without false-positive *blocking*; does not reduce maintenance burden of 64 scripts |
| Partial retention — keep the CI/review merge gates, drop only factcheck/context-budget | Merge gates were the single largest source of false-positive blocks observed (PRE_CREATE/PRE_MERGE misfires); GitHub branch protection already re-implements the same guarantee server-side without local false positives |
| Rewrite gates to be less pattern-matchy (smarter parsing) instead of removing | Ongoing maintenance cost is the root problem, not just false-positive rate; a smarter regex is still a regex; the incident rate on this repo did not justify the engineering investment |

## Consequences

**Pros:**
- Agents are no longer blocked on documentation-only, test-only, or
  read-only commands that merely resemble a dangerous pattern.
- `hooks/` maintenance surface drops from 72 registered commands to 17;
  `settings.json` shrinks accordingly (no `Stop`/`TaskCompleted` keys,
  `PreToolUse Bash` down to 2 entries, `Edit|Write` down to 1).
- Faster session start (fewer SessionStart hooks) and faster per-tool-call
  overhead.

**Cons / explicit operational requirements:**
- Merge safety (CI green, review completed, no unresolved CRITICAL/HIGH)
  now depends entirely on **GitHub branch protection being enabled** on
  `main` and `develop` (required status checks, required reviews, no
  force-push/direct-push allowed at the platform level). This is no
  longer a local-hook responsibility — if branch protection is
  misconfigured or disabled on GitHub, there is no local backstop.
- Review discipline, factchecking, and issue-close verification are now
  guidance in `rules/*.md`, not deterministic gates. Compliance depends on
  the agent/human following the rule, not on an exit-2 block.
- Several protections were retired consciously, not because their
  underlying incidents stopped mattering: state-file tampering, phantom
  completions (#173/#174), and review bypass are still real risk
  categories. The residual mitigations are `verify-agent-output.sh`
  (advisory, still active) plus the human PR-review step on GitHub — a
  deliberately lighter-weight answer than the previous 29-hard-block
  stack.
- ADR-004's mandatory Codex quality-gate pipeline and its 1-concurrent-call
  enforcement are retired (superseded by this ADR): Codex CLI usage is no
  longer gated by `codex-task-gate.sh`; `codex-parallel.sh` /
  `codex-orchestrate.sh` remain available as optional utilities invoked at
  the user's/agent's discretion. ADR-001's PostToolUse Quality Loop
  (`post-lint-format.sh`) is unaffected and remains active.
