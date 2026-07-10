# Hooks Reference

This directory holds every Claude Code hook script wired up in
`settings.json`. `setup.sh` copies them to `~/.claude/hooks/` so the
runtime can execute them.

> **Active Hooks: 17** (4 blocking + 13 advisory/infra) across 5 events.
> See [ADR-006](../docs/adr/006-minimal-safety-net.md) for why this set
> is deliberately small — merge safety and review discipline are handled
> by GitHub branch protection and the PR review workflow, not by local
> hooks. Numbers in this file are generated from `settings.json` — see
> [Verification](#verification) for the exact `jq` queries.

---

## Table of Contents

- [Quick Stats](#quick-stats)
- [Events](#events)
  - [SessionStart](#sessionstart)
  - [PreToolUse](#pretooluse)
  - [PostToolUse](#posttooluse)
  - [PostToolUseFailure](#posttoolusefailure)
  - [PreCompact](#precompact)
- [Inline Hooks](#inline-hooks)
- [Helper Scripts (manual utilities)](#helper-scripts-manual-utilities)
- [_unused/ Archive](#_unused-archive)
- [settings.json vs settings.local.json](#settingsjson-vs-settingslocaljson)
- [Verification](#verification)

---

## Quick Stats

| Metric | Value |
|---|---|
| Events covered | 5 (`SessionStart`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`) |
| Active hooks | 17 |
| Hard blocks (exit 2 possible) | 4 |
| Advisory / infra hooks (never block) | 13 |
| Archived in `_unused/` | 62 scripts (56 retired by ADR-006 + 6 from earlier retirements) + the whole former `gate-modes/` directory |

There is no `Stop` or `TaskCompleted` hook registered — session-end and
task-completion gating were retired (see ADR-006). Test verification and
merge readiness are the agent's/human's responsibility, backstopped by CI
and GitHub branch protection.

---

## Events

Each table lists every `(hook, matcher)` pair registered in
`settings.json → hooks.<Event>`. "Purpose" is condensed from each
script's header comment.

### SessionStart

No matcher. 6 hooks, fired once at session boot. All advisory/infra —
none of these block the session from starting.

| Hook | Purpose |
|---|---|
| `auto-init-permissions.sh` | Intentional no-op; permissions are source-of-truth in `settings.json` |
| `validate-no-local-hooks.sh` | Warn if `settings.local.json` declares a `hooks` section (would overwrite globals) |
| `validate-provider-env.sh` | Check API provider routing (Anthropic subscription vs z.ai) is sane |
| `enforce-branch-workflow.sh` | Auto-create `develop`, warn if currently on `main`/`develop` |
| `enforce-hook-deploy-integrity.sh` | MD5 compare `hooks/*.sh` vs `~/.claude/hooks/`, auto-sync mismatches, detect orphans |
| `auto-update-plugins.sh` | Update third-party plugins on a 24h cooldown |

### PreToolUse

3 invocations across 2 matchers — the only hard blocks in the system.

#### Matcher: `Bash` (2)

| Hook | Purpose |
|---|---|
| `protect-branches.sh` | **Blocks** (`exit 2`) deletion of protected branches (`develop`, `main`, `master`) |
| `git-push-guard.sh` | **Blocks** (`exit 2`) force-push and direct push to protected branches. All other lint/CI-setup checking was removed — see ADR-006 |

#### Matcher: `Edit\|Write` (1)

| Hook | Purpose |
|---|---|
| `block-local-hooks-write.sh` | **Blocks** (`exit 2`) `settings.local.json` writes that would override the global `hooks` section |

### PostToolUse

5 invocations across 3 matchers. Advisory only — informational context,
never a hard block.

#### Matcher: `Agent` (2)

| Hook | Purpose |
|---|---|
| `verify-agent-output.sh` | Detect agent phantom completions (false "done" reports, #173) — informational |
| `auto-commit-worktree-changes.sh` | Auto-commit worktree agent changes after merge to parent dir (#220) |

#### Matcher: `Bash` (2)

| Hook | Purpose |
|---|---|
| `post-deploy-verify.sh` | Inject verification checklist after `gcloud run deploy`/`docker push` |
| `enforce-hook-deploy-after-merge.sh` | Auto-deploy hooks after a PR merge that touched `hooks/` (#183) |

#### Matcher: `Edit\|Write` (1)

| Hook | Purpose |
|---|---|
| `post-lint-format.sh` | Post-write Quality Loop: auto-fix phase → residual check (ADR-001/003) |

### PostToolUseFailure

2 invocations across 2 matchers.

| Hook | Matcher | Purpose |
|---|---|---|
| `notify-agent-failure.sh` | `Agent` | Inject concise failure summary into parent session; persist failure metadata |
| `tool-failure-recovery.sh` | `Bash\|Edit\|Write\|Grep\|WebFetch\|WebSearch` | Inject error-recovery guidance on tool failure (#66 Fix #6) |

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
entry). This inline hook is not counted in the 17 active hooks above
(that count is script files only).

---

## Helper Scripts (manual utilities)

Not registered in `settings.json`. Invoke manually.

> Project-wide automation scripts (not hook-scoped) live in
> [`../scripts/`](../scripts/README.md) — e.g. `codex-parallel.sh`,
> `codex-orchestrate.sh`, `sanitize-local-permissions.sh`. Three
> review-pipeline helper scripts (`review-comment-set-hash.sh`,
> `review-evidence-status.sh`, `verify-pr-review.sh`) were retired to
> `scripts/_unused/` alongside this hook reduction. `check-pr-reviews.sh`
> and `classify-review-state.sh` remain in `scripts/` — they are still
> invoked by the `review-loop` and `classify-review` skills.

---

## _unused/ Archive

`hooks/_unused/` holds every hook retired by [ADR-006](../docs/adr/006-minimal-safety-net.md)
(56 scripts) plus the entire former `hooks/gate-modes/` dispatcher
architecture (`pre-create.sh`, `pre-merge.sh`, `post-push.sh`, `stop.sh`,
`verify.sh`, `cleanup.sh`, `common.sh`), kept for traceability but **not
registered** and **not copied** by `setup.sh`.

This includes the entire former PR review/CI merge-gate stack
(`pr-ci-review-gate.sh` + `gate-modes/*`, `block-merge-without-ci.sh`,
`block-merge-without-review.sh`, `pr-merge-claude-review-gate.sh`,
`enforce-review-reading.sh`, `inject-claude-review-*`), the factcheck
suite, the context-budget suite, the Codex single-call gate
(`codex-task-gate.sh` / `codex-task-release.sh`), `block-codex-mcp.sh`,
`enforce-codex-delegation.sh` / `enforce-codex-for-impl.sh`, the
state-file tampering pair, `protect-linter-config.sh`,
`block-version-downgrade.sh`, `enforce-architecture-layers.sh`,
`enforce-git-freshness.sh`, `enforce-uat-evidence.sh`,
`stop-test-gate.sh`, `task-completion-gate.sh`,
`block-subagent-github-write.sh`, `enforce-develop-base.sh`,
`enforce-soak-time.sh`, `enforce-follow-up-limit.sh`,
`enforce-post-merge-validation.sh`, the `record-*-review` pair,
`verify-test-falsifiability.sh`, `audit-docker-build-args.sh`,
`block-local-permissions-write.sh`, `post-merge-close-issues.sh`,
`post-pr-create-review-trigger.sh`, `git-commit-guard.sh`,
`block-manual-merge-ops.sh`, `pr-guard.sh`, and the remaining scripts
listed by `ls hooks/_unused/`.

**Do not re-register these in `settings.json`.** They remain on disk so
the reduction is self-documenting and reversible if a future incident
justifies reinstating a specific gate. If you do reinstate one, add it
back through the normal path (script → `setup.sh` copy → `settings.json`
registration → verified firing) per `rules/hook-deployment.md`.

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

`validate-no-local-hooks.sh` warns on any `hooks` section in
`settings.local.json` (would overwrite the global hook graph), and
`block-local-hooks-write.sh` hard-blocks an Edit/Write that would create
one. (The equivalent `permissions`-write guards, `validate-no-local-permissions.sh`
and `block-local-permissions-write.sh`, were retired with the rest of the
gate stack in ADR-006; `setup.sh` still runs
`scripts/sanitize-local-permissions.sh` to strip stray `permissions`
blocks from both local locations while preserving their `env`.)

---

## Verification

All counts in this README are reproducible from `settings.json`:

```bash
# Events covered
jq -r '.hooks | keys[]' settings.json

# Total hook invocations
jq '[.hooks | to_entries[] | .value[] | .hooks[]] | length' settings.json

# Unique registered commands (script files only, excludes inline Python)
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
"Quick Stats" table and the corresponding event section so the README
and `settings.json` cannot drift.
