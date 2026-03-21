# Writing Effective Descriptions

The description field is the #1 factor in whether your skill triggers correctly.

## Structure Formula

```
[What it does] + [When to use it] + [Key capabilities]
```

## Good Examples

```yaml
# Specific and actionable
description: Analyzes Figma design files and generates developer handoff documentation. Use when user uploads .fig files, asks for "design specs", "component documentation", or "design-to-code handoff".

# Includes trigger phrases
description: Manages Linear project workflows including sprint planning, task creation, and status tracking. Use when user mentions "sprint", "Linear tasks", "project planning", or asks to "create tickets".

# Clear scope with negative triggers
description: End-to-end customer onboarding workflow for PayFlow. Handles account creation, payment setup, and subscription management. Use when user says "onboard new customer", "set up subscription", or "create PayFlow account". Do NOT use for general payment queries or billing support.

# Clear value with file type mention
description: PayFlow payment processing for e-commerce. Use specifically for online payment workflows, not for general financial queries.
```

## Bad Examples

```yaml
# Too vague - won't trigger reliably
description: Helps with projects.

# Missing triggers - Claude can't decide when to load
description: Creates sophisticated multi-page documentation systems.

# Too technical, no user context
description: Implements the Project entity model with hierarchical relationships.

# Too broad - will overtrigger
description: Processes documents.
```

## Checklist

- [ ] Explains WHAT the skill does (1 sentence)
- [ ] Lists WHEN to use it with specific trigger phrases
- [ ] Includes "Do NOT use for..." negative triggers
- [ ] Under 1024 characters
- [ ] No XML angle brackets
- [ ] Mentions relevant file types if applicable
- [ ] Includes specific tasks users might say
