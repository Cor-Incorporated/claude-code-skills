# Hooks Reference

This directory holds every Claude Code hook script wired up in
`settings.json`. `setup.sh` copies them to `~/.claude/hooks/` so the
runtime can execute them.

> **Active Hooks: 70 unique commands (69 `.sh` scripts + 1 inline Python)
> across 7 events and 84 total invocations.**
> Numbers in this file are generated from `settings.json` — see
> [Verification](#verification) for the exact `jq` queries.

---

## Table of Contents

- [Quick Stats](#quick-stats)
- [Events](#events)
  - [SessionStart](#sessionstart)
  - [PreToolUse](#pretooluse)
  - [PostToolUse](#posttooluse)
  - [PostToolUseFailure](#posttoolusefailure)
  - [Stop](#stop)
  - [TaskCompleted](#taskcompleted)
  - [PreCompact](#precompact)
- [Inline Hooks](#inline-hooks)
- [Helper Scripts (manual utilities)](#helper-scripts-manual-utilities)
- [gate-modes/ Architecture](#gate-modes-architecture)
- [_unused/ Archive](#_unused-archive)
- [settings.json vs settings.local.json](#settingsjson-vs-settingslocaljson)
- [Phase 1–3 Refactor Summary](#phase-13-refactor-summary)
- [Verification](#verification)

---

## Quick Stats

| Metric | Value |
|---|---|
| Events covered | 7 (`SessionStart`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `TaskCompleted`, `PreCompact`) |
| Total hook invocations | 84 |
| Unique registered commands | 70 (69 `.sh` + 1 inline Python) |
| `gate-modes/` modules | 7 (`pre-create`, `pre-merge`, `post-push`, `stop`, `verify`, `cleanup`, `common`) |
| Archived in `_unused/` | 6 (see [_unused/ Archive](#_unused-archive)) |

---

## Events

Each table lists every `(hook, matcher)` pair registered in
`settings.json → hooks.<Event>`. "Purpose" is condensed from each
script's header comment.

### SessionStart

No matcher. 8 hooks, fired once at session boot.

| Hook | Matcher | Purpose |
|---|---|---|
| `validate-no-local-permissions.sh` | — | Block `settings.local.json` from overriding `permissions` (would wipe repo allowlist) |
| `auto-init-permissions.sh` | — | Intentional no-op; permissions are source-of-truth in `settings.json` |
| `context-budget-reset.sh` | — | Reset context-budget gate counters for a fresh session |
| `reset-factcheck.sh` | — | Reset factcheck-done flag |
| `enforce-git-freshness.sh` (`CLAUDE_HOOK_EVENT=SessionStart`) | — | Auto-fetch + warn if local branch is behind remote |
| `validate-no-local-hooks.sh` | — | Warn if `settings.local.json` declares a `hooks` section (would overwrite globals) |
| `enforce-branch-workflow.sh` | — | Auto-create `develop`, warn if currently on `main`/`develop` |
| `enforce-hook-deploy-integrity.sh` | — | MD5 compare `hooks/*.sh` vs `~/.claude/hooks/`, auto-sync mismatches, detect orphans |

### PreToolUse

44 invocations across 9 matchers.

#### Matcher: `Agent` (3)

| Hook | Purpose |
|---|---|
| `context-budget-agent-gate.sh` | Block `isolation:"worktree"`; force `TeamCreate` for 2+ impl agents; warn at 3+ |
| `enforce-codex-delegation.sh` | Advisory warn when Agent is used for Codex-appropriate tasks (#208) |
| `enforce-codex-for-impl.sh` | Warn when impl tasks go to sub-agents instead of Codex CLI route C (ADR-004, #189) |

#### Matcher: `AskUserQuestion` (1)

| Hook | Purpose |
|---|---|
| `enforce-factcheck-before-user-request.sh` | Block manual-operation requests (dashboard/config) without prior factcheck |

#### Matcher: `Bash` (20)

| Hook | Purpose |
|---|---|
| `protect-branches.sh` | Block deletion of protected branches (`develop`, `main`, `master`) |
| `git-push-guard.sh` | Consolidated push guard: protected-ref enforcement + CI/CD setup check |
| `codex-task-gate.sh` | Delegate test/doc creation to Codex; enforce single consolidated Codex call |
| `block-manual-merge-ops.sh` | Block `cherry-pick`/`merge`/`rebase` (delegate to Codex CLI) |
| `git-commit-guard.sh` | Consolidated commit guard: format + issue ref + zero-tolerance + branch whitelist |
| `audit-docker-build-args.sh` | Audit `docker build --build-arg` for `http://` URLs (Mixed Content risk) |
| `enforce-issue-close-verification.sh` | Force acceptance-criteria verification before `gh issue close` |
| `enforce-uat-evidence.sh` | Require concrete UAT/UX/E2E/browser evidence on completion claims |
| `enforce-factcheck-github-ops.sh` | Force factcheck before `gh issue comment`/`gh issue create`/`gh pr create` |
| `block-state-file-tampering-bash.sh` | Block state-file tampering via Bash (fail-closed, multi-line aware) |
| `enforce-develop-base.sh` | Block `git checkout -b` from `main`; block `gh pr create` targeting `main` when `develop` exists |
| `pr-ci-review-gate.sh` (`GATE_MODE=PRE_MERGE`) | Block `gh pr merge` unless CI green + reviews verified (Phase 3 consolidated) |
| `enforce-review-reading.sh` | Block `gh pr merge` if `pending-review-comments.json` has unread CRITICAL/HIGH |
| `enforce-soak-time.sh` | Enforce soak time before merge (develop→main 12h, infra 24h/4h) |
| `block-subagent-github-write.sh` | Block ask-gated git/GitHub writes from subagents/team workers |
| `pr-ci-review-gate.sh` (`GATE_MODE=PRE_CREATE`) | Block `gh pr create` unless review pipeline completed |
| `enforce-deploy-verify-on-pr.sh` | Block PR if changed `hooks/*.sh` or `scripts/*` are not deployed |
| `enforce-follow-up-limit.sh` | Feature freeze after 2 consecutive fix PRs in the same feature family |
| `pr-guard.sh` | Consolidated PR-create guard: target `develop`, issue ref, conflict check |
| `inject-claude-review-on-checks.sh` | Fetch reviews on `gh pr checks`; hard-block `gh pr merge` on unresolved CRITICAL/HIGH |

#### Matcher: `Edit` (6)

| Hook | Purpose |
|---|---|
| `block-local-permissions-write.sh` | Block `permissions` writes to `settings.local.json` |
| `block-state-file-tampering.sh` | Block direct writes to protected state files |
| `context-budget-edit-write-gate.sh` | Block code changes after too many source-code reads |
| `enforce-factcheck-before-edit.sh` | Block Write/Edit unless a factcheck (context7/WebSearch/Read-docs) has run |
| `block-version-downgrade.sh` | Block any version downgrade across all files |
| `protect-linter-config.sh` | Block modification of linter/formatter/type-checker configs |

#### Matcher: `Edit|Write` (5)

| Hook | Purpose |
|---|---|
| `codex-task-gate.sh` | Same Codex delegation gate as the Bash matcher |
| `enforce-architecture-layers.sh` | Block domain→infrastructure imports (DDD Dependency Rule) |
| `enforce-seed-data-verification.sh` | Block writes to `knowledge/seed` files without verification |
| `enforce-git-freshness.sh` (`CLAUDE_HOOK_EVENT=PreToolUse`) | Block edits if local is behind remote |
| `block-local-hooks-write.sh` | Block `hooks` writes to `settings.local.json` |

#### Matcher: `Read` (1)

| Hook | Purpose |
|---|---|
| `context-budget-read-gate.sh` | Track read count per session; warn at 3+, block at 4+ unique source-code reads |

#### Matcher: `WebSearch` (1)

See [Inline Hooks](#inline-hooks) — appends the current year to
non-temporal queries.

#### Matcher: `Write` (6)

| Hook | Purpose |
|---|---|
| `block-local-permissions-write.sh` | Same as Edit matcher |
| `block-state-file-tampering.sh` | Same as Edit matcher |
| `context-budget-edit-write-gate.sh` | Same as Edit matcher |
| `context-budget-write-gate.sh` | Detect new test/doc file creation (delegate to Codex CLI) |
| `enforce-factcheck-before-edit.sh` | Same as Edit matcher |
| `protect-linter-config.sh` | Same as Edit matcher |

#### Matcher: `mcp__codex__.*` (1)

| Hook | Purpose |
|---|---|
| `block-codex-mcp.sh` | Block Codex MCP usage — CLI route only (delegation.md, Issue #72) |

### PostToolUse

26 invocations across 7 matchers.

#### Matcher: `Agent` (4)

| Hook | Purpose |
|---|---|
| `track-agent-team.sh` | Track Agent launches; signal parallel-team via `~/.claude/state/parallel-team.json` |
| `record-code-review.sh` | Record `code-reviewer` completion in `review-status.json` |
| `verify-agent-output.sh` | Detect agent phantom completions (false "done" reports, #173) |
| `auto-commit-worktree-changes.sh` | Auto-commit worktree agent changes after merge to parent dir (#220) |

#### Matcher: `Bash` (13)

| Hook | Purpose |
|---|---|
| `mark-factcheck-done.sh` | Set factcheck-done flag after research/deploy tools |
| `codex-task-release.sh` | Release `codex_call_count` after a Codex CLI call completes (#31) |
| `verify-codex-output.sh` | Detect Codex CLI phantom completions (#174) |
| `record-codex-review.sh` | Record Codex review completion (dual-write: global + project state) |
| `post-merge-close-issues.sh` | Auto-close linked Issues after PR merge (`Closes #NN`) |
| `post-deploy-verify.sh` | Inject verification checklist after `gcloud run deploy`/`docker push` |
| `enforce-hook-deploy-after-merge.sh` | Auto-deploy hooks after a PR merge that touched `hooks/` (#183) |
| `verify-state-file-integrity.sh` | Post-Bash integrity check for protected state files (#157) |
| `enforce-memory-update-on-commit.sh` | Warn if `MEMORY.md currentDate` is stale after a significant commit |
| `enforce-post-merge-validation.sh` | Notify post-merge validation checklist for migration/Terraform/deploy changes |
| `pr-ci-review-gate.sh` (`GATE_MODE=POST_PUSH`) | Set pessimistic review lock after every `git push` |
| `workflow-sync-guard.sh` | Warn when workflow files are pushed to non-main branches (OIDC sync) |
| `post-pr-create-review-trigger.sh` | Auto-trigger review pipeline after `gh pr create` (#72) |

#### Matcher: `Edit|Write` (5)

| Hook | Purpose |
|---|---|
| `verify-test-falsifiability.sh` | Check test docstring vs assertion mismatch (PR #321 incident) |
| `enforce-domain-naming.sh` | Flag non-DDD naming in `domain/` layer (Manager/Handler/Utils/…) |
| `enforce-endpoint-dataflow.sh` | Remind to verify full client→API→backend data flow on route edits |
| `enforce-doc-update-scope.sh` | Remind to update all related docs when editing doc files |
| `post-lint-format.sh` | Post-write Quality Loop: auto-fix phase → residual check (ADR-001/003) |

#### Matchers: `Grep`, `Read`, `WebSearch|WebFetch`, `mcp__plugin_context7_context7__.*` (1 each)

All four invoke the same script for the same reason.

| Hook | Purpose |
|---|---|
| `mark-factcheck-done.sh` | Mark factcheck done after any research tool used |

### PostToolUseFailure

2 invocations across 2 matchers.

| Hook | Matcher | Purpose |
|---|---|---|
| `notify-agent-failure.sh` | `Agent` | Inject concise failure summary into parent session; persist failure metadata |
| `tool-failure-recovery.sh` | `Bash\|Edit\|Write\|Grep\|WebFetch\|WebSearch` | Inject error-recovery guidance on tool failure (#66 Fix #6) |

### Stop

No matcher. 2 hooks.

| Hook | Purpose |
|---|---|
| `pr-ci-review-gate.sh` (`GATE_MODE=STOP`) | Informational warnings on session stop; never blocks (#181) |
| `stop-test-gate.sh` | Run change-related test gate before session end (#66 Fix #3) |

### TaskCompleted

No matcher. 1 hook.

| Hook | Purpose |
|---|---|
| `task-completion-gate.sh` | Block premature task completion; verify CI + review status (#66 Fix #2) |

### PreCompact

No matcher. 1 hook.

| Hook | Purpose |
|---|---|
| `pre-compact-context-save.sh` | Save critical state to `additionalContext` before compaction (#146) |

---

## Inline Hooks

One registered hook is an inline Python snippet rather than a script
file. It is registered under `PreToolUse → WebSearch` and appends the
current year to queries that lack a year and any temporal keyword
(`latest`, `recent`, `current`, `new`, `now`, `today`). It returns a
`PreToolUse` `modifiedToolInput` JSON payload.

When adding or modifying this logic, edit the `command` string directly
inside `settings.json` (the `hooks.PreToolUse[matcher=WebSearch]`
entry).

---

## Helper Scripts (manual utilities)

These scripts live under `hooks/` but are **not** registered in
`settings.json`. Invoke them manually.

| Script | Purpose |
|---|---|
| `inject-claude-review-helper.py` | Python helper invoked by `inject-claude-review-on-checks.sh`; fetches PR review comments and emits `hookSpecificOutput` JSON. Three modes: claude-review summary, other reviews, or "review needed" warning. |
| `context-budget-set-mode.sh` | Manually switch context-budget gate mode: `planning`, `research`, or `auto`. State file is otherwise write-protected. |

> Project-wide automation scripts (not hook-scoped) live in
> [`../scripts/`](../scripts/README.md) — e.g. `codex-parallel.sh`,
> `codex-orchestrate.sh`, `sanitize-local-permissions.sh`,
> `review-evidence-status.sh`.

---

## gate-modes/ Architecture

`pr-ci-review-gate.sh` is an **83-line thin dispatcher**. It reads
`GATE_MODE` (env var or `$1`) and routes to one of seven mode scripts
under `hooks/gate-modes/`:

| Mode | Script | Trigger | Behavior |
|---|---|---|---|
| `PRE_CREATE` | `pre-create.sh` | `GATE_MODE=PRE_CREATE` on `Bash` (PreToolUse) | Hard-block `gh pr create` unless the review pipeline is complete |
| `PRE_MERGE` | `pre-merge.sh` | `GATE_MODE=PRE_MERGE` on `Bash` (PreToolUse) | Hard-block `gh pr merge` unless CI is green and reviews are verified |
| `POST_PUSH` | `post-push.sh` | `GATE_MODE=POST_PUSH` on `Bash` (PostToolUse) | Set a pessimistic review lock after every `git push` |
| `STOP` | `stop.sh` | `GATE_MODE=STOP` (Stop event) | Informational warnings; never blocks (#181) |
| `VERIFY` | `verify.sh` | Manual: `bash pr-ci-review-gate.sh VERIFY <PR>` | Manual verification called by the agent after review |
| `CLEANUP` | `cleanup.sh` | Manual: `GATE_MODE=CLEANUP` | Remove merged/closed PRs from lock + review state |
| (shared) | `common.sh` | Sourced by all mode scripts | Shared helpers: state dir resolution, `gh` invocation, repo resolution, severity parsing |

Key design points:

- **No subagent exemption** for `PRE_CREATE`/`PRE_MERGE`/`POST_PUSH` —
  subagents must not create or merge PRs without review, and POST_PUSH
  must still invalidate stale evidence after child-session pushes. Only
  `STOP` exempts subagents.
- **Phase 3 consolidation**: `pre-merge.sh` (502 lines) absorbed three
  earlier scripts — `pr-merge-claude-review-gate.sh`,
  `block-merge-without-ci.sh`, and `block-merge-without-review.sh` —
  into a unified 5-gate sequence (CI completed → CI green → comments
  exist → `review_read` current per #151 → CRITICAL acknowledged). The
  consolidation rule is "do not weaken vs. the union of the originals".
- **`common.sh`** holds the shared helper functions added during
  Phase 3 so each mode script stays focused on its gate sequence.

---

## _unused/ Archive

Scripts kept for traceability but **no longer registered**. Each was
absorbed by a consolidated gate during Phase 1–3.

| Script | Reason for retirement |
|---|---|
| `enforce-ci-check.sh` | Superseded by `pr-guard.sh` (consolidated PR-create guard) |
| `post-push-review-check.sh` | Folded into `pr-ci-review-gate.sh` `POST_PUSH` mode |
| `validate-hook-deployment.sh` | Replaced by `enforce-hook-deploy-integrity.sh` (auto-sync + orphan detection) |
| `block-merge-without-ci.sh` | Phase 3 — absorbed by `gate-modes/pre-merge.sh` |
| `block-merge-without-review.sh` | Phase 3 — absorbed by `gate-modes/pre-merge.sh` |
| `pr-merge-claude-review-gate.sh` | Phase 3 — absorbed by `gate-modes/pre-merge.sh` |

Do not re-register these in `settings.json`. They remain on disk so the
git history of the consolidation is self-documenting.

---

## settings.json vs settings.local.json

`setup.sh` **overwrites** `~/.claude/settings.json` from this repo's
`settings.json` on every run. Anything that must survive a re-install
must live in `settings.local.json`, which Claude Code merges on top
(local takes precedence).

- **Repo-owned (this `settings.json`)**: `permissions.allow`, `hooks`,
  `model`, `enabledPlugins`, project-wide config.
- **Local-only (`~/.claude/settings.local.json`)**: API tokens, base
  URL, model overrides, anything machine-specific.

Two SessionStart guards enforce this split:

- `validate-no-local-permissions.sh` blocks `permissions` in
  `settings.local.json` (would overwrite the repo allowlist).
- `validate-no-local-hooks.sh` warns on any `hooks` section in
  `settings.local.json` (would overwrite the global hook graph).

`setup.sh` step 2 also runs `scripts/sanitize-local-permissions.sh` to
strip stray `permissions` blocks from both local locations while
preserving their `env`.

---

## Phase 1–3 Refactor Summary

This comprehensive refactor flattened a sprawling hook graph into a
smaller, auditable set of consolidated gates.

**Phase 1 — consolidation of redundant single-purpose hooks**

- `git-commit-guard.sh` merged `enforce-commit-format`,
  `enforce-issue-reference-on-commit`, and
  `enforce-zero-tolerance-precommit` into one shell entry.
- `git-push-guard.sh` merged `enforce-push-strategy` and
  `enforce-cicd-setup`.
- `pr-guard.sh` absorbed `enforce-ci-check.sh` plus the PR-create half
  of `enforce-develop-base`.
- `enforce-hook-deploy-integrity.sh` replaced
  `validate-hook-deployment.sh`, adding MD5 auto-sync and orphan
  detection.

**Phase 2 — review-pipeline centralization**

- `pr-ci-review-gate.sh` became the single entry point for the PR
  review/CI gate, absorbing `enforce-review-pipeline.sh` (PRE_CREATE)
  and `post-push-review-check.sh` (POST_PUSH).

**Phase 3 — `gate-modes/` split**

- The dispatcher was thinned to 83 lines and the per-mode logic moved
  into `gate-modes/{pre-create,pre-merge,post-push,stop,verify,cleanup}.sh`,
  sharing `common.sh`.
- `pre-merge.sh` (502 lines) unified the three remaining
  `gh pr merge` blockers — `pr-merge-claude-review-gate.sh`,
  `block-merge-without-ci.sh`, `block-merge-without-review.sh` —
  behind one 5-gate sequence with the explicit rule "do not weaken vs.
  the union of the originals".
- `common.sh` collects the helpers shared across modes.

**Net effect**: 7 single-purpose scripts retired into `_unused/`, the
PR-merge gate path is now one script + one dispatcher entry instead of
three, and every gate mode is independently testable.

---

## Verification

All counts in this README are reproducible from `settings.json`:

```bash
# Events covered
jq -r '.hooks | keys[]' settings.json

# Total hook invocations
jq '[.hooks | to_entries[] | .value[] | .hooks[]] | length' settings.json

# Unique registered commands (69 .sh + 1 inline Python = 70)
jq -r '
  [.hooks | to_entries[] | .value[] | .hooks[] | .command]
  | map([scan("hooks/([A-Za-z0-9._-]+\\.sh)")] | if length > 0 then .[0] else "INLINE_PYTHON" end)
  | unique | length
' settings.json

# Full event / matcher / script table
jq -r '
  .hooks | to_entries[] | .key as $event | (.value // [])[]
  | (.matcher // "(none)") as $matcher
  | .hooks[] | .command
  | [ $event, $matcher,
      ([scan("hooks/([A-Za-z0-9._-]+\\.sh)")] | if length > 0 then .[0] else "INLINE_PYTHON" end)
    ] | @tsv
' settings.json
```

If you add or remove a hook, re-run these queries, then update the
"Quick Stats" table and the corresponding event section so the
README and `settings.json` cannot drift.
