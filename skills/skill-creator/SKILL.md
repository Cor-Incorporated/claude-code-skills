---
name: skill-creator
description: Interactive guide for creating, reviewing, and optimizing Claude skills. Walks users through use case definition, frontmatter generation, instruction writing, validation, and packaging. Use when user says "create a skill", "build a skill", "make a new skill", "design a skill", "optimize my skill", "review this skill", or "improve this skill". Do NOT use for general coding tasks, writing documentation, or non-skill file creation.
allowed-tools: [Read, Write, Bash, Grep, Glob]
---

# Skill Creator

Create effective skills through a structured 6-step process.

## Core Principles

1. **Context window is shared** - Only include what Claude doesn't already know. Challenge each paragraph: "Does this justify its token cost?"
2. **Progressive disclosure** - Metadata (~100 words, always loaded) -> SKILL.md body (<5k words, on trigger) -> references/ (as needed, unlimited)
3. **Match freedom to fragility** - Narrow bridge = specific guardrails (scripts), open field = flexible guidance (text)
4. **Concise examples over verbose explanations** - Show, don't tell

## Skill Structure

```
skill-name/
├── SKILL.md          # Required - YAML frontmatter + Markdown instructions
├── scripts/          # Optional - Executable code (deterministic, token-efficient)
├── references/       # Optional - Docs loaded into context as needed
└── assets/           # Optional - Templates, fonts, icons used in output
```

No README.md, CHANGELOG.md, or auxiliary documentation inside the skill folder.

## Creation Process

### Step 1: Understand Use Cases

Ask the user for 2-3 concrete examples:
- "What would a user say to trigger this skill?"
- "What multi-step workflows does this require?"
- "Which tools are needed (built-in or MCP)?"
- "What domain knowledge or best practices should be embedded?"

Skip only when usage patterns are already clear.

### Step 2: Plan Reusable Contents

For each example, identify reusable resources:
- **scripts/**: Code rewritten repeatedly (e.g., `rotate_pdf.py`, `validate_fields.py`)
- **references/**: Documentation needed during execution (e.g., `schema.md`, `api-docs.md`)
- **assets/**: Files used in output (e.g., `template.pptx`, `boilerplate/`)

### Step 2b: Determine Scope (Global vs Project-Local)

Ask the user or determine from context where the skill should live:

| Scope | Criteria | Install Path | Example |
|-------|----------|-------------|---------|
| **Global** | Tech-stack agnostic, useful across all projects | `~/.claude/skills/` | code-reviewer, tdd-workflow, git-commit-helper |
| **Project-local** | Depends on specific project config, services, or architecture | `.claude/skills/` (repo root) | supabase-nextjs-debugger, gcp-deploy-guardian |
| **Organization** | Team-wide workflow/policy enforcement | Deployed via admin (Claude.ai) or shared repo | review-loop, CI policy skills |

**Decision questions:**
- "Does this skill reference project-specific services (Supabase, Cloud Run, specific APIs)?" → Project-local
- "Would this skill work identically in any TypeScript/Python/Go repo?" → Global
- "Is this a team policy that should apply to all members?" → Organization

**Why this matters:** Global skills count toward the per-session limit (recommended 20-50). Over-installing globally leads to context window pressure and description conflicts. When in doubt, start project-local and promote to global only after confirmed reuse.

### Step 3: Initialize

Run the initialization script to scaffold:

```bash
python scripts/init_skill.py <skill-name> --path <output-directory>
```

Skip if updating an existing skill.

### Step 4: Edit

#### 4a. Write Frontmatter

The description is the primary trigger mechanism. Follow this structure:

```
[What it does] + [When to use it] + [Key capabilities]
```

CRITICAL rules:
- Include specific trigger phrases users would say
- Include negative triggers ("Do NOT use for...")
- Under 1024 characters, no XML angle brackets
- Only `name` and `description` are required
- Optional fields: `license`, `allowed-tools`, `metadata`, `compatibility`

See `references/description-guide.md` for good/bad examples and the full checklist.

#### 4b. Implement Resources

1. Create scripts, references, assets identified in Step 2
2. Test scripts by actually running them
3. Delete example files not needed (init creates placeholders)

For scripts: ensure deterministic reliability, test with real inputs.
For references: if >10k words, include grep search patterns in SKILL.md.
For assets: verify file paths and formats work as expected.

#### 4c. Write Instructions

- **Imperative form**: "Run X", "Check Y" (not "You should run X")
- **Specific and actionable**: `Run python scripts/validate.py --input {filename}` not "Validate the data"
- **Critical info first**: Use `## Critical` or `## Important` headers at the top
- **Under 500 lines**: Move details to references/
- **Error handling**: Include what to do when things fail
- **Examples**: Add input/output pairs for complex operations
- **No duplication**: Information lives in SKILL.md OR references, not both
- **Conditional attention**: Wrap task-specific sections in `<important if="condition">` tags so Claude focuses on them only when relevant. Use specific conditions (e.g., `if="you are deploying to production"`), not broad ones. Leave universal rules unconditional. See `references/attention-tags.md` for details and examples.

Pattern guides for reference:
- **Multi-step processes**: See `references/workflows.md`
- **Output formats**: See `references/output-patterns.md`

### Step 5: Validate and Package

```bash
python scripts/package_skill.py <path/to/skill-folder> [output-dir]
```

Validates automatically, then creates a `.skill` file. Fix errors and re-run if validation fails.

The validator checks: frontmatter format, naming conventions, description quality, body length, file structure, and common mistakes.

### Step 6: Iterate

Test with real tasks. Watch for signals:

- **Undertriggering** (doesn't load when it should) -> Add more trigger phrases to description
- **Overtriggering** (loads for irrelevant queries) -> Add negative triggers, narrow scope
- **Instructions not followed** -> Move critical info to top, use bullet points, be more specific
- **Inconsistent results** -> Add examples, improve error handling

See `references/testing-guide.md` for the full testing approach.
See `references/troubleshooting.md` for common issues and fixes.

## Performance Notes

- Take your time to do this thoroughly
- Quality is more important than speed
- Do not skip validation steps
