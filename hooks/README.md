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
| Events covered | 7 (`SessionStart`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`, `UserPromptSubmit`, `Stop`) |
| Registered entries | 29 (the pinned count is `docs/CANONICAL-STATE.md`, link-tested by `tests/test-pairs-link.sh` pair13) |
| Hard blocks (exit 2 possible) | 4 (+ the H17 common control, which blocks via JSON `permissionDecision: deny` / `decision: block`) |
| Archived in `_unused/` | 62 scripts (56 retired by ADR-006 + 6 from earlier retirements) + the whole former `gate-modes/` directory |

`TaskCompleted` gating was retired (ADR-006). `Stop` is registered again since
2026-10-14 for the **H17 common control** (aidd-governance#174): the same
oracle `hooks/lib/aidd_cc.py` sits on the Claude Code, Codex, Cursor, OpenCode
and Pi entries and stops (a) the 4th identical command with no progress delta,
(b) re-asking a confirmation the user already answered, (c) a completion /
save claim without executed, fresh, output-matched `Evidence:` /
`Readback:` trailers. It never auto-allows anything (ADR-006). A degraded
control (crash, missing module, max-blocks release that would have blocked)
is announced as a `systemMessage` and an H6 ledger `error` / `would-block`
row — never a silent pass. Entry files: `aidd-cc-claude.sh`,
`codex/aidd-cc-codex.sh`, `cursor/aidd-cc-cursor.sh`, `../opencode/aidd-cc.ts` (1.x fork build),
`../opencode/aidd-cc-v2/index.ts` (upstream 2.x directory plugin, launcher `../opencode/launcher/opencode2`),
`../pi/aidd-cc.ts`, `../dsh/aidd-cc.patch.yml` (+ `aidd-cc-native.mts`, unverified);
replay of the 47 dot incidents: `tests/dot-replay/run_replay.py` (arms: claude /
codex / cursor / opencode (1.x plugin) / opencode2 (2.x plugin, `opencode2_driver.ts`) / pi).

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
| `protect-branches.sh` | **Blocks** (`exit 2`) deletion of protected branches (`develop`, `main`, `master`) and any push that updates one, including implicit pushes (`git push`, `git push origin HEAD`) resolved against the input's `.cwd`, `cd <dir>` and `git -C <dir>` (F22, `tests/test-hard-block-implicit-push.sh`) |
| `git-push-guard.sh` | **Blocks** (`exit 2`) force-push and direct push to protected branches, explicit or implicit (both call the shared destination resolver `hooks/lib/push_dests.py`). All other lint/CI-setup checking was removed — see ADR-006 |

#### Matcher: `Edit\|Write` (1)

| Hook | Purpose |
|---|---|
| `block-local-hooks-write.sh` | **Blocks** (`exit 2`) `settings.local.json` writes that would override the global `hooks` section |
| `aidd-cc-claude.sh` (`git commit` via Bash) | H17 repair-family breaker (aidd-governance#88): the 4th `fix(<scope>)` commit of one scope in a session with no re-adjudication is **blocked**. A re-adjudication is a `note` whose hypothesis carries `STRATEGY: HOLD\|PIVOT\|RETIRE`; HOLD counts **once per scope per PIVOT/RETIRE cycle** (a second HOLD is ignored — this harness's own loop on claude-code-skills#418 was "satisfied" by 4 HOLDs). Branch-wide: ≥ 6 `fix(<scope>)` commits since the merge-base with develop/main (first-parent, across sessions) block the next one in any session until a commit body carries `ADJUDICATION: <issue or PR comment url>` — the owner's decision; that commit (or the pending commit's own `-m`) passes and cuts both counters. Repository = `git -C` / `cd <dir> &&` in the command, else cwd; not a repo → 0; ≤ 6 s, a timeout is an H6 `error` row **ADR-013 (2026-10-25)**: a ruling url releases exactly one commit — the same `ADJUDICATION:` url on a second `fix(<scope>)` commit of the branch is spent and blocks; a scope gets at most 3 rulings per branch, after which the branch is closed for `fix(<scope>)` and the work moves to a new branch whose PR states the pivot (opencode#353 rode one url through 7 follow-up fixes). |

### PostToolUse

8 invocations across 4 matchers. Advisory only — informational context,
never a hard block. (`aidd-cc-claude.sh` on `Bash|Edit|Write|MultiEdit|AskUserQuestion`
is the H17 common control, listed under PreToolUse.)

#### Matcher: `Agent` (2)

| Hook | Purpose |
|---|---|
| `verify-agent-output.sh` | Detect agent phantom completions (false "done" reports, #173) — informational |
| `auto-commit-worktree-changes.sh` | Auto-commit worktree agent changes after merge to parent dir (#220) |

#### Matcher: `Bash` (4)

| Hook | Purpose |
|---|---|
| `post-deploy-verify.sh` | Inject verification checklist after `gcloud run deploy`/`docker push`/`kubectl apply`. The words count anywhere except inside a heredoc body that is not run by a shell and the quoted text of grep/rg/echo/printf |
| `enforce-hook-deploy-after-merge.sh` | Auto-deploy hooks after a PR merge that touched `hooks/` (#183) |
| `aidd-async-register.sh` | Register background/async work so the turn boundary can reconcile it (aidd-governance#96) |
| `harness-guardrail-ledger.sh` | Copy claude-code-harness plugin fires (RUNTIME_FLOOR / R01–R13) from `<project>/.claude/state/audit/guardrail-fires.jsonl` into `guard-ledger.jsonl` (ADR-006 req. 4; the floor deny fires no PostToolUseFailure). Rule id + category only, never the command |

#### Matcher: `Edit\|Write` (1)

| Hook | Purpose |
|---|---|
| `post-lint-format.sh` | Post-write Quality Loop: auto-fix phase → residual check (ADR-001/003). Write-mode fixers run only when the project declares the tool and the committed version is already clean, so they never restyle lines the edit did not touch. A new file that is staged but not yet committed is not auto-formatted (git cannot show a committed version to compare with) |

### PostToolUseFailure

2 invocations across 2 matchers.

| Hook | Matcher | Purpose |
|---|---|---|
| `notify-agent-failure.sh` | `Agent` | Inject concise failure summary into parent session; persist failure metadata |
| `tool-failure-recovery.sh` | `Bash\|Edit\|Write\|Grep\|WebFetch\|WebSearch` | Inject error-recovery guidance on tool failure (#66 Fix #6). Bash failures are classified by exit code (1 from grep/rg = no match, 126, 127) and by anchored error lines, not by phrases anywhere in the output |

### PreCompact

No matcher. 1 hook.

| Hook | Purpose |
|---|---|
| `pre-compact-context-save.sh` | Save critical state to `additionalContext` before compaction (#146) |

### UserPromptSubmit

No matcher. 1 hook.

| Hook | Purpose |
|---|---|
| `aidd-cc-claude.sh` | H17: register user decisions (for re-ask suppression only), deadlines (`6h以内`, write-once) and the declared denominator (`全47ケース`) |

### Stop

No matcher. 3 hooks.

| Hook | Purpose |
|---|---|
| `aidd-h3-evidence-stop.sh` | H3: warn when a completion claim has no `Evidence:` trailer (warn only; superseded by H17's block) |
| `aidd-turn-boundary-stop.sh` | Carry-over ledger: stop only the session that registered async work |
| `aidd-cc-claude.sh` | H17 evidence gate (ADR-009, aidd-governance `docs/adr/009-status-declaration-protocol.md`): once the session has used a tool, the final answer must end with one line `Status: complete \| partial \| unverified`. `complete` (or a full `Evidence:` trailer) is **bound** to the ledger: cited commands executed, not stale, output field matches, rc 0; `Readback:` sha must match a file this session wrote. `partial` / `unverified` pass with a `systemMessage` and an `evidence.status-partial` row. Entry visibility of that note: Claude Code `systemMessage`, Pi `custom_message`, OpenCode appended to the text part; Cursor has no message-only stop output (`followup_message` would re-prompt) so only the H6 row carries it. OpenCode headless (`opencode run`) never reaches `session.idle` work, so the last text part no tool call followed is judged at process exit (Status required): verdict on stderr + H6 row. No `Status:` line → **block**. The gate does not infer a claim from prose (no negation / retraction / exemption rules); sessions with no tool rows keep the closed vocabulary as a backstop only. Releases (`stop_hook_active`, max-blocks) are evaluated and announced (`systemMessage` + `would-block` ledger row) |

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
