# Claude Code Skills

**English** | [日本語](README.ja.md)

A curated collection of skills, rules, and hooks for [Claude Code](https://claude.com/claude-code) — Anthropic's official CLI for Claude.

This repository provides a production-ready Claude Code configuration with 27 custom skills, 37 hook scripts, 5 rule sets, and integration with third-party skill frameworks.

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
├── hooks/            # 37 hook scripts (quality gates, safety guards, workflow enforcement)
├── scripts/          # 5 utility scripts (Codex orchestration, PR review, context monitoring)
├── setup.sh          # One-command installation
├── settings.json     # Template settings (sanitized, no personal paths)
└── README.md
```

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
  code-reviewer, review-loop, e2e, bugfix + 37 hook scripts

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

## Hook System (37 Scripts)

### Quality Gates (Pre-merge)
- `block-merge-without-ci.sh` — Block merge without CI green
- `block-merge-without-review.sh` — Block merge without review approval
- `pr-ci-review-gate.sh` — 3-mode gate (PRE_CREATE / POST_PUSH / STOP)
- `pr-merge-claude-review-gate.sh` — Claude review LGTM required
- `pr-guard.sh` — Base branch, issue ref, conflict checks

### Safety Guards
- `protect-branches.sh` — Prevent deletion of protected branches
- `block-manual-merge-ops.sh` — Block cherry-pick/merge/rebase (delegate to Codex)
- `git-push-guard.sh` — Push safety checks
- `git-commit-guard.sh` — Commit message and scope validation
- `block-version-downgrade.sh` — Prevent dependency downgrades
- `audit-docker-build-args.sh` — Check for http:// in Docker build args

### Context Budget Management
- `context-budget-read-gate.sh` — Warn/block after 3+ source file reads
- `context-budget-write-gate.sh` — Detect test/doc creation for Codex delegation
- `context-budget-edit-write-gate.sh` — Block edits when too many files read
- `context-budget-agent-gate.sh` — Monitor agent spawning count
- `context-budget-reset.sh` — Reset counters on session start

### Workflow Enforcement
- `enforce-git-freshness.sh` — Block edits if behind remote
- `enforce-factcheck-before-edit.sh` — Require fact-check before modifying infra
- `enforce-factcheck-before-user-request.sh` — Fact-check before asking user for manual ops
- `enforce-architecture-layers.sh` — Validate domain/core layer modifications
- `enforce-domain-naming.sh` — DDD naming convention enforcement
- `enforce-endpoint-dataflow.sh` — Full data flow verification for API changes
- `enforce-seed-data-verification.sh` — Verify seed data against reference docs
- `enforce-issue-close-verification.sh` — Check acceptance criteria before closing issues
- `enforce-review-reading.sh` — Read all review comments before merge
- `enforce-memory-update-on-commit.sh` — Warn if MEMORY.md is stale after commit
- `enforce-doc-update-scope.sh` — Validate documentation update scope

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

MIT
