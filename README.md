# Claude Code Skills

**English** | [日本語](README.ja.md)

A curated collection of skills, rules, and hooks for [Claude Code](https://claude.com/claude-code) — Anthropic's official CLI for Claude.

This repository provides a production-ready Claude Code configuration with 27 custom skills, 17 hook scripts (4 blocking + 13 advisory/infra), 6 rule sets, 6 utility scripts, and integration with third-party skill frameworks.

> **Design Philosophy**: This project implements the principles from [Harness Engineering Best Practices 2026](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/) — deterministic quality gates via hooks, pointer-based documentation (ADR-002), and the feedback speed hierarchy (PostToolUse > pre-commit > CI > human review). Since [ADR-006](docs/adr/006-minimal-safety-net.md), the hook set is deliberately minimal: hard blocks are reserved for destructive/irreversible operations, and merge safety is delegated to GitHub branch protection + PR review rather than local gates.

## Quick Start

```bash
git clone https://github.com/terisuke/claude-code-skills.git
cd claude-code-skills
chmod +x setup.sh
./setup.sh
```

Restart Claude Code after installation.


## API provider (Anthropic subscription ↔ z.ai)

Claude Code can only use one API gateway per process. This repo ships `scripts/claude-provider.sh` so you can switch between the **official Claude subscription** (default, reliable for subagents/WebSearch) and **z.ai GLM**.

```bash
bash ~/.claude/scripts/claude-provider.sh status
bash ~/.claude/scripts/claude-provider.sh anthropic   # default
bash ~/.claude/scripts/claude-provider.sh zai
```

Details: [docs/runbooks/provider-switching.md](docs/runbooks/provider-switching.md).

## Repository Structure

```
claude-code-skills/
├── skills/           # 27 custom skill definitions (SKILL.md + scripts + references)
├── rules/            # 6 global rule files (coding-style, git-workflow, quality, testing, delegation, hook-deployment)
├── hooks/            # 17 hook scripts (4 blocking + 13 advisory/infra); hooks/_unused/ holds 56 retired scripts (ADR-006)
├── scripts/          # 6 utility scripts (Codex orchestration, provider switching, context monitoring); scripts/_unused/ holds retired review-pipeline helpers
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
| [005](docs/adr/005-plans-json-migration.md) | Plans.md → JSON Migration | Rejected |
| [006](docs/adr/006-minimal-safety-net.md) | Minimal Safety Net — Hook Reduction | Accepted |

To add a new ADR, use the [template](docs/adr/template.md).

## References

| Document | Description |
|----------|-------------|
| [Harness Engineering Best Practices 2026](docs/references/harness-engineering-best-practices-2026.md) | Summary of the article that underpins this repository's design philosophy |
| [The Complete Guide to Building Skills for Claude](docs/references/The-Complete-Guide-to-Building-Skills-for-Claude.pdf) | Anthropic official guide — skill structure, progressive disclosure, testing, distribution ([summary](docs/references/anthropic-skill-guide-summary.md)) |

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
  code-reviewer, review-loop, e2e, bugfix + 17 hook scripts

Reflect (gstack)
  /retro
```

## Skills Inventory

### Development Workflow
| Skill | Purpose | Trigger |
|-------|---------|---------|
| `code-reviewer` | PR review with OWASP security checks | "review this PR", "code review" |
| `codex-review` | Codex CLI second opinion review (parallel experts via `codex exec`) | "Codex レビュー", "セカンドオピニオン" |
| `classify-review` | AI-based PR review severity re-classification (false positive filter) | /classify-review [PR#] |
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
| **A: Review** | Code review, second opinion (parallel experts) | `codex exec --sandbox read-only` / `codex-review` skill |
| **B: Handover** | Large implementation (requires user judgment) | Create handover doc → user passes to Codex |
| **C: Parallel** | Independent tasks in isolated worktrees | `codex-parallel.sh` or `codex-orchestrate.sh` |

### Codex Delegation (Manual, Not Hook-Gated)

Since [ADR-006](docs/adr/006-minimal-safety-net.md), Codex CLI usage and
context-budget management are **not** enforced by hooks — the previous
`context-budget-*-gate.sh` suite and the 1-concurrent-call
`codex-task-gate.sh`/`codex-task-release.sh` pair were retired. Route
selection (Agent Team vs. Codex vs. self-execute) is agent judgement
guided by `rules/delegation.md`; `codex-parallel.sh` /
`codex-orchestrate.sh` remain available as optional utilities invoked at
will, with no concurrency limit enforced locally.

### Utility Scripts

| Script | Purpose |
|--------|---------|
| `codex-parallel.sh` | Single-task Codex execution with auto sandbox selection |
| `codex-orchestrate.sh` | Multi-task parallel execution via worktrees (JSON or CSV input) |
| `claude-provider.sh` | Switch API gateway between Anthropic subscription and z.ai |
| `sanitize-local-permissions.sh` | Strip stray `permissions` blocks from local settings files |
| `delivery_score.py` | Quantitative delivery quality scoring (hook coverage, CI, reviews) |
| `context-monitor.py` | Monitor context window usage and token consumption |

`check-pr-reviews.sh`, `classify-review-state.sh`,
`review-comment-set-hash.sh`, `review-evidence-status.sh`, and
`verify-pr-review.sh` were retired to `scripts/_unused/` along with the
review-pipeline hooks they supported (ADR-006).

## Merge Safety (GitHub-Side, Not a Local Hook)

Prior to ADR-006, a multi-gate `pr-ci-review-gate.sh` + `gate-modes/`
pipeline hard-blocked `gh pr create`/`gh pr merge` locally. That pipeline
is retired. Merge safety is now the responsibility of **GitHub branch
protection** (required status checks, required reviews, no force-push)
configured on `main`/`develop`, plus the ordinary PR review workflow
(`code-reviewer` skill, optional Codex CLI second opinion via
`codex-review`). If branch protection is disabled or misconfigured on
GitHub, there is no local backstop — see
[ADR-006's consequences](docs/adr/006-minimal-safety-net.md#consequences)
for the explicit operational requirement this creates.


## Design Philosophy

This repository is built on three foundational principles:

### 1. Harness Engineering Best Practices (2026)

Based on [the article](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/) that underpins this system's architecture:

| Principle | Implementation | Coverage |
|-----------|---------------|----------|
| Deterministic tools, minimally applied | 17 hook scripts (4 blocking + 13 advisory) | ADR-006 |
| Feedback speed hierarchy | PostToolUse (ms) > pre-commit > CI (min) > review (hr) | ADR-003 |
| Pointer-based documentation | Rules ≤50 lines each (total 122 lines), pointing to ADRs/hooks | ADR-002 |
| Plan-execute separation | Plans.md + plan mode + planner agent | TaskCreate/Update |
| Git as cross-session bridge | `auto-commit-worktree-changes.sh` + memory files | PostToolUse |
| Claude Code + Codex hybrid | 60/40 split, delegation now agent-judgement (not hook-gated) | ADR-004, ADR-006 |

Since ADR-006, this repository intentionally trades some of the original
article's "deterministic tools over LLM prompts everywhere" guidance for a
smaller, higher-signal hook set — see
[docs/adr/006-minimal-safety-net.md](docs/adr/006-minimal-safety-net.md)
for the false-positive-cost rationale.

### 2. Epic #130: "Implemented ≠ Working"

The core operational principle, born from an incident where 11 of 18 hooks (61%) were "implemented" in source code but never actually fired:

> **"Code exists" and "system works" are separate verification steps. Code review alone cannot guarantee operational correctness.**

This principle is enforced through:
- **4-stage verification**: Code exists → Syntax OK → Registered in settings.json → Actually fires
- **`delivery_score.py`**: Quantitative quality scoring (hook coverage, CI pass rate, review compliance)
- **`enforce-hook-deploy-integrity.sh`**: Source ↔ deployed ↔ registered consistency check (auto-sync + orphan detection)
- **CI/CD**: shellcheck + JSON validation + syntax checking on every PR

**Before Epic #130**: Hook gate operation rate 39% (7/18)
**After Epic #130, before ADR-006**: Hook gate operation rate 98%+ (59/59 hooks registered + deployed)
**After ADR-006 (current)**: 17/17 hooks registered + deployed — the surviving set is smaller by design, not by drift; deploy-integrity verification still applies to all of it.

### 3. Delivery Quality Score

Run `python3 scripts/delivery_score.py` to get a quantitative quality assessment:

```
==================================================
  Delivery Quality Score: claude-code-skills
==================================================
  Total: 99.0/100 (A+)
──────────────────────────────────────────────────
  hook_coverage            :  96.5/100
  ci_pass_rate             : 100.0/100
  soak_time                : 100.0/100
  review_compliance        : 100.0/100
==================================================
```

Use `--json` for CI/automation integration.

## Known Issues & Roadmap

All P1-HIGH issues from the Epic #130 review (2026-03-24) have been resolved.
P2-MEDIUM issues #136-#147 resolved in subsequent PRs. Current open items:

| Issue | Description | Status |
|-------|-------------|--------|
| [#161](../../issues/161) | `delegation.md` 327→50 lines (ADR-002, #107 reopened) | Fixed in this release |

## Hook System (17 Scripts)

Full per-hook reference (event, matcher, purpose): [hooks/README.md](hooks/README.md).
Rationale for the reduction from 72 registered commands down to 17:
[ADR-006](docs/adr/006-minimal-safety-net.md).

### Blocking (4 — hard PreToolUse block, exit 2)
- `git-push-guard.sh` — Block force-push and direct push to protected branches
- `protect-branches.sh` — Prevent deletion of protected branches
- `block-local-hooks-write.sh` — Prevent `settings.local.json` from overriding global hooks
- `validate-no-local-hooks.sh` — Warn/block at SessionStart if such an override already exists

### Advisory / infra (13 — informational, never block)
- `auto-init-permissions.sh` — No-op; permissions live in `settings.json`
- `auto-update-plugins.sh` — Update third-party plugins (24h cooldown)
- `validate-provider-env.sh` — Check API provider routing (Anthropic/z.ai) at session start
- `enforce-branch-workflow.sh` — Auto-create develop branch, warn on `main`/`develop`
- `enforce-hook-deploy-integrity.sh` — Verify hooks are installed and registered (auto-sync + orphan detection)
- `enforce-hook-deploy-after-merge.sh` — Auto-deploy hooks after a PR merge that touched `hooks/`
- `verify-agent-output.sh` — Detect agent phantom completions (#173)
- `auto-commit-worktree-changes.sh` — Auto-commit worktree agent changes after merge (#220)
- `post-deploy-verify.sh` — Inject verification checklist after deploy commands
- `post-lint-format.sh` — Post-write Quality Loop: auto-fix → residual check (ADR-001/003)
- `notify-agent-failure.sh` — Propagate agent failure context (PostToolUseFailure)
- `tool-failure-recovery.sh` — Error-recovery guidance on tool failure (PostToolUseFailure)
- `pre-compact-context-save.sh` — Save critical context before compaction (PreCompact)

56 previously-active scripts (the full review/CI merge-gate stack,
factcheck suite, context-budget suite, Codex single-call gate, state-file
tampering guards, and more) plus the entire former `hooks/gate-modes/`
dispatcher architecture are retired to `hooks/_unused/`. See
[hooks/README.md#_unused-archive](hooks/README.md#_unused-archive) for
the full retired list and the rationale in ADR-006.

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

See the [official hooks documentation](https://code.claude.com/docs/en/hooks) for details.

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
