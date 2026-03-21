# Conditional Attention Tags (`<important if="">`)

## What They Are

`<important if="condition">` tags are conditional wrapper tags that focus Claude's attention on specific instructions only when the condition is met. Based on HumanLayer's research into Claude's behavior with system-level instructions.

## Why They Matter

Claude wraps CLAUDE.md content in `<system_reminder>` tags marked as "may or may not be relevant." In long files, sections get partially ignored because Claude distributes attention across the entire context. Conditional `<important>` tags solve this by narrowing attention — Claude pays full attention to the wrapped content only when the condition matches the current task, effectively reducing noise for unrelated work.

## Best Practices for Skill Authors

### What to wrap conditionally
- Domain-specific guardrails that apply only during certain tasks
- Deployment/environment-specific rules
- Format requirements for specific output types
- Tool-specific instructions

### What to leave unconditional
- Project identity, structure, and tech stack (applies to nearly every task)
- Universal coding standards and security rules
- Any rule that applies >80% of the time

### Write specific conditions

**Bad** (too broad, matches almost everything):
```xml
<important if="you are writing code">
```

**Good** (narrow, matches only relevant tasks):
```xml
<important if="you are modifying database schema or migrations">
<important if="you are writing or modifying tests">
<important if="you are deploying to production">
<important if="you are modifying API endpoints">
<important if="you are working with authentication">
```

### Don't over-wrap
If a rule applies to most tasks, wrapping it in a condition adds complexity without benefit. Reserve `<important if="">` for rules that are critical in specific contexts but irrelevant noise otherwise.

## Example for Skill Authors

```xml
<!-- In a skill's SKILL.md -->
<important if="the user is creating a new skill">
- Every skill MUST have YAML frontmatter with name and description
- Description should be <300 chars and include trigger phrases
- Use progressive disclosure: metadata -> SKILL.md body -> references/
</important>

<important if="the user is optimizing an existing skill">
- Challenge each paragraph: "Does this justify its token cost?"
- Move verbose reference material to references/ subdirectory
- Ensure trigger phrases in description are specific, not broad
</important>
```

## Integration with Skill Creation Workflow

When creating or editing skills (Step 4), consider which instruction sections are task-conditional:

1. Identify sections that only matter for specific user intents
2. Wrap them in `<important if="condition">` with a specific condition
3. Leave universal rules (project identity, tech stack, security) unconditional
4. Test that the conditions are neither too broad nor too narrow
