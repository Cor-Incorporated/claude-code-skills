# Claude Code Skills

**English** | [日本語](README.ja.md)

A curated collection of skills, rules, and hooks for [Claude Code](https://claude.com/claude-code) — Anthropic's official CLI for Claude.

This repository provides a production-ready Claude Code configuration with 27 custom skills, 52 hook scripts, 5 rule sets, and integration with third-party skill frameworks.

## Quick Start

```bash
git clone https://github.com/terisuke/claude-code-skills.git
cd claude-code-skills
chmod +x setup.sh
./setup.sh
```

Restart Claude Code after installation.

## Repository Structure

```
claude-code-skills/
├── skills/           # 27 custom skill definitions (SKILL.md + scripts + references)
├── rules/            # 5 global rule files (coding-style, git-workflow, quality, testing, delegation)
├── hooks/            # 52 hook scripts (quality gates, safety guards, workflow enforcement)
├── scripts/          # 5 utility scripts (Codex orchestration, PR review, context monitoring)
├── setup.sh          # One-command installation
├── settings.json     # Template settings (sanitized, no personal paths)
└── README.md
```

## Architecture Decision Records (ADR)

Design decisions are recorded as ADRs in `docs/adr/`.

| ADR | Title | Status |
|-----|-------|--------|
| [001](docs/adr/001-posttooluse-quality-loop.md) | PostToolUse Quality Loop | Accepted |
| [002](docs/adr/002-pointer-design-principle.md) | CLAUDE.md Pointer Design Principle | Accepted |
| [003](docs/adr/003-feedback-speed-hierarchy.md) | Feedback Speed Hierarchy | Accepted |
| [004](docs/adr/004-codex-delegation-model.md) | Codex Large-Scale Delegation Model | Accepted |

To add a new ADR, use the [template](docs/adr/template.md).

## References

| Document | Description |
|----------|-------------|
| [Harness Engineering Best Practices 2026](docs/references/harness-engineering-best-practices-2026.md) | Summary of the article that underpins this repository's design philosophy |

See [docs/references/](docs/references/) for details.

## Third-Party Dependencies

This configuration integrates with the following third-party skill frameworks. They are **not bundled** in this repository — `setup.sh` installs them automatically.

| Package | Author | License | Purpose | Install |
|---------|--------|---------|---------|---------|
| [gstack](https://github.com/garrytan/gstack) | Garry Tan (YC) | MIT | Think/Plan phase skills: /office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /retro + QA/browse tools | `git clone` + `./setup` |
| [ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | nextlevelbuilder | Open Source | UI/UX design intelligence: 67 styles, 96 palettes, 57 font pairings, 13 tech stacks | `npm install -g uipro-cli` + `uipro init --ai claude` |

### Hybrid Architecture

```
Think → Plan (gstack)
  /office-hours → /plan-ceo-review → /plan-eng-review → /plan-design-review

Build → Review → Ship (custom skills + hooks)
  code-reviewer, review-loop, e2e, bugfix + 52 hook scripts

Reflect (gstack)
  /retro
```

## Skills Inventory

### Development Workflow
| Skill | Purpose | Trigger |
|-------|---------|---------|
| `code-reviewer` | PR review with OWASP security checks | "review this PR", "code review" |
| `review-loop` | CI green + review LGTM auto-loop | /review-loop |
| `bugfix` | Root cause analysis + fix all instances | /bugfix [description] |
| `tdd-workflow` | RED-GREEN-REFACTOR cycle enforcement | "write tests first", "TDD" |
| `test-falsify` | Verify tests actually detect declared bugs | /test-falsify |
| `git-commit-helper` | Conventional commit message generation | "commit this" |
| `changelog-generator` | User-friendly release notes from git history | "create changelog" |

### Architecture & Design
| Skill | Purpose | Trigger |
|-------|---------|---------|
| `modern-architecture` | DDD + Clean Architecture + CQRS patterns | "clean architecture", "DDD" |
| `senior-architect` | System design with architecture diagrams | "design the system" |
| `senior-frontend` | React/Next.js/Tailwind development | "create component" |
| `senior-backend` | Python/Node.js/Go backend development | "design an API" |
| `senior-fullstack` | Full-stack scaffolding and patterns | "scaffold a new project" |
| `ui-skills` | Tailwind CSS constraints and accessibility | "review this component" |
| `ui-design-system` | Design token generation | "generate design tokens" |

### DevOps & Infrastructure
| Skill | Purpose | Trigger |
|-------|---------|---------|
| `gcp-deploy-guardian` | GCP deployment failure prevention | docker build, gcloud deploy |
| `supabase-nextjs-debugger` | Supabase + Next.js bug diagnosis | "Vercel 404", "RLS error" |
| `security-review` | OWASP Top 10 vulnerability audit | "security review" |

### Productivity
| Skill | Purpose | Trigger |
|-------|---------|---------|
| `agent-orchestrator` | Multi-agent team composition | 3+ parallel tasks |
| `skill-creator` | Interactive skill creation guide | "create a skill" |
| `brainstorming` | Pre-implementation idea exploration | "brainstorm", "let's think through" |
| `file-organizer` | Directory cleanup and deduplication | "organize my files" |
| `developer-growth-analysis` | Coding pattern analysis + Slack report | "analyze my growth" |
| `adk-engineer` | Google ADK agent implementation | "ADK agent" |
| `ux-researcher-designer` | Persona generation, journey mapping | "create persona" |
| `gws-workspace` | Google Workspace CLI operations | "Google Drive", "Sheets" |
| `context7-skills` | Context7 CLI skill management | "search skills", "ctx7" |

## Agent Architecture & Codex Delegation

This system's core differentiator is its **multi-agent orchestration** with automatic delegation to Codex CLI.

### Claude Code + Codex CLI Hybrid Model

```
Claude Code (60%) — Design, parallel implementation, coordination, user interaction
  └─ Strengths: Agent teams, real-time judgment, context-shared collaboration

Codex CLI (40%) — Sequential implementation, operations, quality audits
  └─ Strengths: Worktree isolation, long-running autonomy, GitHub/Supabase integration
```

### Subagent & Agent Team System

| Pattern | When to Use | Example |
|---------|------------|---------|
| **Single agent** | Isolated, known-scope task | "Fix this lint error" |
| **Parallel agents (2-4)** | Independent tasks, no dependencies | Frontend + backend changes in parallel |
| **Agent team (5-7)** | Complex multi-file features with cross-review | New feature with tests + docs + review |
| **Agent Team (worktree)** | Lightweight 1-2 file changes, docs | Dockerfile fix, config change, doc creation |
| **Codex delegation** | Long-running, mechanical, or >5-turn tasks | Bulk test creation, large refactors |

The `agent-orchestrator` skill manages team composition, wave-based execution, and cross-review protocols.

### Three Codex Delegation Pathways

| Route | Purpose | Command |
|-------|---------|---------|
| **A: Review** | Code review, second opinion | `codex exec review --base <branch>` |
| **B: Handover** | Large implementation (requires user judgment) | Create handover doc → user passes to Codex |
| **C: Parallel** | Independent tasks in isolated worktrees | `codex-parallel.sh` or `codex-orchestrate.sh` |

### Context Budget Gate (Automatic)

Hook scripts automatically enforce delegation rules:

```
Task received
├─ 2+ independent tasks? → Agent Team (TeamCreate)
├─ 1 task + long-running + autonomous + large? → Codex CLI Route C (single task only)
├─ <3 files to read? → Claude Code (self-execute)
├─ Test/doc creation (single task)? → Codex CLI Route C
├─ >5 expected turns (single task)? → Codex CLI Route C
└─ Needs real-time judgment? → Claude Code (main)
```

**Important**: Codex CLI is limited to **one task at a time**. Multiple independent tasks must use Agent Team (TeamCreate), not Codex orchestration.

| Hook | Trigger | Action |
|------|---------|--------|
| `context-budget-read-gate.sh` | Read tool | Warn at 3+ files, strong warn at 6+ |
| `context-budget-write-gate.sh` | Write tool | Detect test/doc creation → suggest Codex |
| `context-budget-edit-write-gate.sh` | Edit/Write | Block when too many source files read |
| `context-budget-agent-gate.sh` | Agent tool | Block 2+ foreground impl agents, warn on 1st, enforce background/TeamCreate |
| `codex-task-gate.sh` | Bash (Codex exec) | Block 2nd+ Codex CLI call (1 concurrent limit) |
| `codex-task-release.sh` | PostToolUse Bash | Release Codex counter after task completes (enables sequential reuse) |

### Utility Scripts

| Script | Purpose |
|--------|---------|
| `codex-parallel.sh` | Single-task Codex execution with auto sandbox selection |
| `codex-orchestrate.sh` | Multi-task parallel execution via worktrees (JSON or CSV input) |
| `check-pr-reviews.sh` | Verify PR review timestamps against latest push |
| `verify-pr-review.sh` | Validate review coverage before merge |
| `context-monitor.py` | Monitor context window usage and token consumption |

## Review Pipeline (PR Merge Gate)

Every PR must pass a **multi-gate review pipeline** before merge is allowed. This is enforced automatically by hooks — no manual steps required.

```
PR Ready to Merge?
│
├─ Gate 1: CI All Green? ──────────────── block-merge-without-ci.sh
│  └─ All GitHub Actions checks must be ✅ (not pending, not failed)
│
├─ Gate 2: Review After Latest Push? ──── block-merge-without-review.sh
│  └─ review.submittedAt > last push timestamp (stale reviews rejected)
│
├─ Gate 3: Review Verified? ───────────── pr-ci-review-gate.sh (LIGHT tier 3-pass OR)
│  ├─ Pass A: code-reviewer agent completed (review-status.json)
│  ├─ Pass B: No CRITICAL/HIGH findings (pending-review-comments.json)
│  └─ Pass C: Manual verification (pr-review-lock.json verified=true)
│
├─ Gate 4: Unresolved Comments? ────────── enforce-review-reading.sh
│  └─ All CRITICAL/HIGH review findings must be addressed
│
└─ Gate 5: Review Injection ────────────── inject-claude-review-on-checks.sh
   └─ Auto-fetches review comments on `gh pr checks` / `gh pr merge`
```

### Tiered Review System

Review requirements are automatically adjusted based on what changed:

| Tier | Target | Required Reviews | Detection |
|------|--------|-----------------|-----------|
| **FULL** | Source code changes | code-reviewer + Codex CLI | Changes in `src/`, `lib/`, `app/`, `*.ts`, `*.py`, etc. |
| **LIGHT** | CI/config/docs only | code-reviewer only | Only `.github/workflows/`, `*.md`, `Dockerfile`, `*.yml`, etc. |
| **EXEMPT** | Branch-based | None | `docs/*`, `chore/*`, `ci/*` branches |

This prevents over-engineering review requirements. A CI workflow change doesn't need a Codex CLI second opinion.

### When No External Review Exists

If a PR has no GitHub review (e.g., solo development), the system falls back to a **local review pipeline**:

1. **`code-reviewer` skill** — Automated PR analysis with OWASP security checks, quality scoring
2. **Codex CLI Route A** (FULL tier only) — Independent second opinion: `codex exec review --base <branch>`
3. **Both must pass** (FULL tier) or just step 1 (LIGHT tier) before the PR is considered reviewed

This ensures every PR gets appropriate review depth based on the risk level of changes.

### Housekeeping

Merged or closed PRs are automatically cleaned from the lock state:

- **STOP hook**: Auto-removes merged/closed PR entries via GitHub API
- **Manual cleanup**: `GATE_MODE=CLEANUP bash hooks/pr-ci-review-gate.sh`

### PR Lifecycle Hooks

| Phase | Hook | Action |
|-------|------|--------|
| **PR Create** | `pr-guard.sh` | Validate base branch, issue reference, conflict check |
| **PR Create** | `pr-ci-review-gate.sh` (PRE_CREATE) | Check review pipeline readiness |
| **Post Push** | `pr-ci-review-gate.sh` (POST_PUSH) | Set review lock (new push invalidates old reviews) |
| **Pre Merge** | `pr-ci-review-gate.sh` (PRE_MERGE) | Block merge without CI green + review LGTM |
| **Pre Merge** | All 5 gates above | Block merge unless all pass |
| **Post Merge** | `post-merge-close-issues.sh` | Auto-close linked issues |
| **Session Stop** | `pr-ci-review-gate.sh` (STOP) | Warn about unverified PRs |

## Hook System (52 Scripts)

### Session Initialization
- `auto-init-permissions.sh` — Auto-initialize permissions on session start
- `context-budget-reset.sh` — Reset all counters on session start (incl. `fg_impl_agent_count`)
- `reset-factcheck.sh` — Reset fact-check state on session start
- `enforce-branch-workflow.sh` — Auto-create develop branch, enforce feature branch workflow
- `validate-no-local-hooks.sh` — Validate no hook overrides exist on session start

### Quality Gates (Pre-merge)
- `block-merge-without-ci.sh` — Block merge unless all CI checks green
- `block-merge-without-review.sh` — Block merge unless review is newer than latest push
- `pr-ci-review-gate.sh` — 6-mode gate (PRE_CREATE / PRE_MERGE / POST_PUSH / STOP / VERIFY / CLEANUP) with tiered review
- `pr-merge-claude-review-gate.sh` — 5-sub-gate Claude review enforcement
- `inject-claude-review-on-checks.sh` — Auto-fetch review comments on `gh pr checks` / `gh pr merge`
- `pr-guard.sh` — Base branch, issue ref, conflict checks
- `task-completion-gate.sh` — Block premature task completion (CI pending or CRITICAL/HIGH findings)
- `stop-test-gate.sh` — Run change-related test gate before session end (docs/config-only skip, full-suite fallback, stop_hook_active guard)

### Safety Guards
- `protect-branches.sh` — Prevent deletion of protected branches
- `block-manual-merge-ops.sh` — Block cherry-pick/merge/rebase (sync from main/master/develop is allowed)
- `git-push-guard.sh` — Push safety checks
- `git-commit-guard.sh` — Commit message and scope validation
- `block-version-downgrade.sh` — Prevent dependency downgrades
- `audit-docker-build-args.sh` — Check for http:// in Docker build args
- `block-local-hooks-write.sh` — Prevent settings.local.json from overriding global hooks
- `block-codex-mcp.sh` — Block Codex MCP usage, enforce CLI-only (PreToolUse)
- `block-state-file-tampering.sh` — Prevent AI self-bypass of state files (Write/Edit)
- `block-state-file-tampering-bash.sh` — Prevent AI self-bypass of state files (Bash)
- `protect-linter-config.sh` — Prevent unauthorized linter config modifications

### Context Budget Management
- `context-budget-read-gate.sh` — Warn/block after 3+ source file reads
- `context-budget-write-gate.sh` — Detect test/doc creation for Codex delegation
- `context-budget-edit-write-gate.sh` — Block edits when too many files read
- `context-budget-agent-gate.sh` — Enforce foreground impl agent limits (Rule 2+4), background/TeamCreate governance
- `codex-task-gate.sh` — Block 2nd+ Codex CLI call (1 concurrent limit)
- `codex-task-release.sh` — Release Codex call counter after task completion (PostToolUse)

### Workflow Enforcement
- `enforce-git-freshness.sh` — Block edits if behind remote
- `enforce-factcheck-before-edit.sh` — Require fact-check before modifying infra (non-code files like .yml/.md excluded)
- `enforce-factcheck-before-user-request.sh` — Fact-check before asking user for manual ops
- `enforce-architecture-layers.sh` — Validate domain/core layer modifications
- `enforce-domain-naming.sh` — DDD naming convention enforcement
- `enforce-endpoint-dataflow.sh` — Full data flow verification for API changes
- `enforce-seed-data-verification.sh` — Verify seed data against reference docs
- `enforce-issue-close-verification.sh` — Check acceptance criteria before closing issues
- `enforce-review-reading.sh` — Read all review comments before merge
- `enforce-memory-update-on-commit.sh` — Warn if MEMORY.md is stale after commit
- `enforce-doc-update-scope.sh` — Validate documentation update scope

### Post-Action Hooks
- `record-code-review.sh` — Record code review completion for merge gate tracking
- `record-codex-review.sh` — Record Codex CLI review completion (called by codex-parallel.sh)
- `mark-factcheck-done.sh` — Mark fact-check as completed after research
- `track-agent-team.sh` — Track agent team spawning and completion
- `post-merge-close-issues.sh` — Auto-close linked issues after merge
- `post-deploy-verify.sh` — Post-deployment verification checks
- `post-lint-format.sh` — Run lint and format checks after file edits (PostToolUse Quality Loop)
- `post-pr-create-review-trigger.sh` — Auto-trigger code review after PR creation (PostToolUse)
- `workflow-sync-guard.sh` — Sync workflow state after push
- `verify-test-falsifiability.sh` — Verify tests actually detect declared bugs (PostToolUse)
- `tool-failure-recovery.sh` — Error recovery guidance on tool failure (PostToolUseFailure)

## Hook Matcher Syntax

**Important**: Claude Code's `matcher` field accepts only a **tool name regex**, not an expression language. Command-level filtering must be done inside the hook script by parsing `stdin` JSON.

```json
// CORRECT — matches tool name with regex
{ "matcher": "Bash" }
{ "matcher": "Edit|Write" }

// WRONG — will never fire (treated as regex against tool name)
{ "matcher": "tool == \"Bash\" && tool_input.command matches \"git push\"" }
```

Hook scripts receive the tool invocation as JSON on `stdin` and should filter by inspecting `tool_input.command` or `tool_input.file_path` internally.

### Exit Code Convention (Official Spec)

| Exit Code | Meaning | PreToolUse Behavior |
|-----------|---------|-------------------|
| `0` | Allow | Tool call proceeds. JSON output (if any) is parsed for `hookSpecificOutput`. |
| `2` | Block | Tool call is blocked. `stderr` is fed back to Claude as error message. |
| Other | Non-blocking error | `stderr` shown in verbose mode only. Execution continues. |

**Important**: Do NOT echo the input JSON back to stdout on `exit 0`. The official pattern is simply `exit 0` to allow a tool call. All hooks in this repository follow this convention.

See the [official hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks) for details.

## Rules

| File | Purpose |
|------|---------|
| `coding-style.md` | Immutability, file size limits, Zod validation, security checks |
| `git-workflow.md` | Branch protection, PR granularity, soak time, post-merge verification |
| `quality.md` | Zero-tolerance errors, completion verification, Docker constraints |
| `testing.md` | Coverage 80%+, TDD workflow, test level definitions, falsifiability |
| `delegation.md` | Claude Code vs Codex CLI delegation rules, context budget gates |

---

## Anthropic Official Skill Best Practices

> Based on [The Complete Guide to Building Skills for Claude](https://docs.anthropic.com) (Anthropic, 2026)

### Skill Structure Requirements

```
skill-name/              # kebab-case, no spaces, no capitals
├── SKILL.md             # Required — YAML frontmatter + Markdown instructions
├── scripts/             # Optional — Executable code (deterministic, token-efficient)
├── references/          # Optional — Docs loaded into context as needed
└── assets/              # Optional — Templates, fonts, icons used in output
```

**No README.md, CHANGELOG.md, or auxiliary documentation inside the skill folder.**

### Progressive Disclosure (3 Levels)

1. **YAML frontmatter** — Always loaded in system prompt. Provides just enough for Claude to know WHEN to use the skill.
2. **SKILL.md body** — Loaded when Claude thinks the skill is relevant. Contains full instructions.
3. **references/** — Additional files Claude navigates only as needed.

### Frontmatter Rules

```yaml
---
name: skill-name          # Required. kebab-case, no "claude"/"anthropic" prefix
description: |             # Required. [What] + [When] + [Capabilities]. Under 1024 chars.
  What it does. Use when user says "trigger phrase".
  Do NOT use for: negative triggers.
allowed-tools: [Read, Bash, Grep]  # Optional. Restrict tool access.
license: MIT               # Optional
metadata:                  # Optional
  author: Your Name
  version: 1.0.0
---
```

**CRITICAL: No XML angle brackets (`< >`) in frontmatter.** Frontmatter appears in Claude's system prompt — angle brackets could inject instructions. Use `[placeholder]` instead.

### Description Field Structure

```
[What it does] + [When to use it] + [Key capabilities] + [Do NOT use for]
```

**Good:**
```yaml
description: Analyzes git diff and generates conventional commit messages.
  Use when staging changes or writing commit messages. Do NOT use for
  branching strategy or merge conflict resolution.
```

**Bad:**
```yaml
description: Helps with projects.  # Too vague, no triggers
```

### Instruction Writing Rules

- **Imperative form**: "Run X", "Check Y" (not "You should run X")
- **Specific and actionable**: `Run python scripts/validate.py --input {filename}` not "Validate the data"
- **Critical info first**: Use `## Critical` or `## Important` headers at top
- **Under 500 lines** in SKILL.md body: Move details to `references/`
- **Error handling**: Include what to do when things fail
- **No duplication**: Information lives in SKILL.md OR references/, not both

### Conditional Attention Tags

Use `<important if="condition">` tags in SKILL.md body (NOT in frontmatter) to focus Claude's attention on relevant sections:

```xml
<important if="you are deploying to production">
- Use --platform linux/amd64 for Docker builds
- Use --update-env-vars (NOT --set-env-vars)
</important>
```

**Rules:**
- Keep conditions SPECIFIC (not `if="you are writing code"`)
- Leave universal rules UNCONDITIONAL
- If a rule applies >80% of the time, don't wrap it

### Scope Decision (Global vs Project-Local)

| Scope | Criteria | Path |
|-------|----------|------|
| **Global** | Tech-stack agnostic, useful across all projects | `~/.claude/skills/` |
| **Project-local** | Depends on specific project services/architecture | `.claude/skills/` |
| **Organization** | Team-wide policy enforcement | Admin-deployed |

**Global skills count toward the per-session limit (recommended 20-50).** When in doubt, start project-local.

### Quality Checklist (Before Publishing)

- [ ] Folder named in kebab-case
- [ ] SKILL.md exists (exact spelling, case-sensitive)
- [ ] YAML frontmatter has `---` delimiters
- [ ] `name` field: kebab-case, no spaces, no capitals
- [ ] `description` includes WHAT, WHEN, and DO NOT USE FOR
- [ ] No XML tags (`< >`) in frontmatter
- [ ] Instructions are clear and actionable
- [ ] Error handling included
- [ ] Examples provided
- [ ] References clearly linked
- [ ] `allowed-tools` restricts to minimum necessary tools
- [ ] Tested: triggers on relevant queries, doesn't trigger on unrelated
- [ ] SKILL.md body under 5,000 words

### Performance Guidelines

- Evaluate if >20-50 skills are enabled simultaneously
- Move detailed documentation to `references/` (progressive disclosure)
- Use `allowed-tools` to restrict unnecessary tool access
- Add negative triggers to prevent over-triggering

## Contributing

1. Fork this repository
2. Add or modify skills following the Anthropic best practices above
3. Run the quality checklist before submitting PR
4. Ensure no sensitive information (API keys, project-specific URLs, team names) is included

## License

[MIT](LICENSE)
