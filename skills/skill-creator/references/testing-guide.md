# Testing Skills

## 1. Triggering Tests

Ensure your skill loads at the right times.

**Should trigger:**
- "Help me set up a new ProjectHub workspace"
- "I need to create a project in ProjectHub"
- "Initialize ProjectHub project for Q4 planning"

**Should NOT trigger:**
- "What's the weather in San Francisco?"
- "Help me write Python code"
- "Create a spreadsheet" (unless ProjectHub handles sheets)

**Debug method:** Ask Claude "When would you use the [skill name] skill?" - Claude will quote the description back. Adjust based on what's missing.

## 2. Functional Tests

Verify the skill produces correct outputs.

Test cases:
- Valid outputs generated
- API/MCP calls succeed
- Error handling works
- Edge cases covered

Example:
```
Test: Create project with 5 tasks
Given: Project name "Q4 Planning", 5 task descriptions
When: Skill executes workflow
Then:
    - Project created in ProjectHub
    - 5 tasks created with correct properties
    - All tasks linked to project
    - No API errors
```

## 3. Performance Comparison

Compare the same task with and without skill:

```
Without skill:                    With skill:
- Instructions each time          - Automatic workflow
- 15 back-and-forth messages      - 2 clarifying questions
- 3 failed API calls              - 0 failed API calls
- 12,000 tokens consumed          - 6,000 tokens consumed
```

## Iteration Signals

### Undertriggering
Symptoms: Skill doesn't load when it should, users manually enabling it
Fix: Add more detail and trigger phrases to description

### Overtriggering
Symptoms: Skill loads for irrelevant queries, users disabling it
Fix: Add negative triggers ("Do NOT use for..."), narrow scope

### Execution Issues
Symptoms: Inconsistent results, API call failures, user corrections needed
Fix: Improve instructions, add error handling, add examples
