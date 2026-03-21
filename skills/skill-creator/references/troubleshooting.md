# Troubleshooting Skills

## Skill Won't Upload

### "Could not find SKILL.md"
File must be named exactly `SKILL.md` (case-sensitive).
Verify: `ls -la` should show SKILL.md

### "Invalid frontmatter"
Must use `---` delimiters:
```yaml
# Wrong
name: my-skill
description: Does things

# Correct
---
name: my-skill
description: Does things
---
```

### "Invalid skill name"
Must be kebab-case: lowercase, digits, hyphens only.
```yaml
# Wrong: My Cool Skill, my_cool_skill, MyCoolSkill
# Correct: my-cool-skill
```

## Skill Doesn't Trigger

Checklist:
- Is description too generic? ("Helps with projects" won't trigger reliably)
- Does it include trigger phrases users would actually say?
- Does it mention relevant file types?

Debug: Ask Claude "When would you use the [skill name] skill?" and adjust description.

## Skill Triggers Too Often

1. Add negative triggers: "Do NOT use for [specific scenarios]"
2. Narrow scope: "Use specifically for X workflows, not for general Y queries"
3. Clarify boundaries between similar skills

## Instructions Not Followed

Common causes and fixes:

1. **Too verbose** - Keep concise, use bullet points and numbered lists
2. **Critical info buried** - Put at top with `## Critical` or `## Important` headers
3. **Ambiguous language** - Be specific:
   - Bad: "Make sure to validate things properly"
   - Good: "CRITICAL: Before calling create_project, verify: project name is non-empty, at least one team member assigned, start date is not in the past"
4. **Model laziness** - Add explicit encouragement:
   ```
   ## Performance Notes
   - Take your time to do this thoroughly
   - Quality is more important than speed
   - Do not skip validation steps
   ```

## Large Context Issues

Symptoms: Slow responses, degraded quality

Solutions:
1. Keep SKILL.md under 500 lines / 5,000 words
2. Move detailed docs to references/
3. If 20+ skills enabled simultaneously, consider selective enablement or skill packs

## MCP Connection Issues

Checklist:
1. Verify MCP server is connected (Settings > Extensions)
2. Check API keys are valid and not expired
3. Test MCP independently: "Use [Service] MCP to fetch my projects"
4. Verify tool names are correct (case-sensitive)
