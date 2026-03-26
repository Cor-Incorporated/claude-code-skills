# The Complete Guide to Building Skills for Claude — Summary

## Source
PDF: [The-Complete-Guide-to-Building-Skills-for-Claude.pdf](./The-Complete-Guide-to-Building-Skills-for-Claude.pdf)
URL: https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf

## Chapters

### Ch1: Fundamentals
- Skill = folder with SKILL.md (required) + scripts/ + references/ + assets/
- Progressive Disclosure: frontmatter (always loaded) > SKILL.md body (on relevance) > references/ (on demand)
- Composability: multiple skills simultaneously, work well alongside others
- Portability: works across Claude.ai, Claude Code, and API

### Ch2: Planning and Design
- 3 use case categories: Document & Asset Creation, Workflow Automation, MCP Enhancement
- Success criteria: quantitative (90% trigger rate, X tool calls, 0 API failures) + qualitative (no user corrections, consistent results)
- Technical requirements: SKILL.md (exact case), kebab-case folder/name, no README.md inside skill folder
- YAML frontmatter: name (required, kebab-case), description (required, WHAT+WHEN+DO NOT USE, <1024 chars), no XML `< >` tags
- Description structure: `[What it does] + [When to use it] + [Key capabilities]`
- Instructions: imperative form, specific/actionable, critical info first, <500 lines, error handling included

### Ch3: Testing and Iteration
- 3 test types: triggering (loads at right time), functional (correct output), performance (vs baseline)
- skill-creator tool: generates skills from descriptions, reviews and suggests improvements
- Iteration signals: undertriggering (add keywords) vs overtriggering (add negative triggers, be specific)

### Ch4: Distribution and Sharing
- Individual: download folder > upload via Settings > Capabilities > Skills
- Organization: admin-deployed, workspace-wide, automatic updates
- API: `/v1/skills` endpoint, `container.skills` parameter, Agent SDK compatible
- Open standard: Agent Skills spec, cross-platform portability

### Ch5: Patterns and Troubleshooting
- Pattern 1: Sequential workflow orchestration (explicit step ordering, dependencies, validation)
- Pattern 2: Multi-MCP coordination (clear phase separation, data passing, validation before next phase)
- Pattern 3: Iterative refinement (quality criteria, improvement loop, re-validation)
- Pattern 4: Context-aware tool selection (decision criteria, fallback options, transparency)
- Pattern 5: Domain-specific intelligence (compliance before action, audit trail, governance)
- Troubleshooting: invalid frontmatter, skill won't upload, doesn't trigger, triggers too often, instructions not followed, large context issues, MCP connection issues

### Ch6: Resources and References
- Official: Best Practices Guide, Skills Documentation, API Reference, MCP Documentation
- Tools: skill-creator (built into Claude.ai/Claude Code)
- Public skills: github.com/anthropics/skills
- Support: Claude Developers Discord, github.com/anthropics/skills/issues

## Key Rules for This Repository
1. SKILL.md body under 500 lines (move details to references/)
2. Description under 1024 characters with WHAT + WHEN + DO NOT USE
3. No XML tags in frontmatter (security: appears in system prompt)
4. No README.md inside skill folders
5. 20-50 skills recommended maximum simultaneously enabled
6. Progressive disclosure to minimize token usage
