# Output Patterns

Use these patterns when skills need to produce consistent, high-quality output.

## Template Pattern

For strict requirements (API responses, data formats):
```markdown
## Report structure

ALWAYS use this exact template:

# [Analysis Title]
## Executive summary
[One-paragraph overview]
## Key findings
- Finding 1 with supporting data
- Finding 2 with supporting data
## Recommendations
1. Specific actionable recommendation
2. Specific actionable recommendation
```

For flexible guidance (when adaptation is useful):
```markdown
## Report structure

Sensible default format - adjust sections as needed:

# [Analysis Title]
## Executive summary
[Overview]
## Key findings
[Adapt based on what you discover]
## Recommendations
[Tailor to context]
```

## Examples Pattern

For skills where output quality depends on seeing examples, provide input/output pairs:

```markdown
## Commit message format

**Example 1:**
Input: Added user authentication with JWT tokens
Output:
feat(auth): implement JWT-based authentication

Add login endpoint and token validation middleware

**Example 2:**
Input: Fixed bug where dates displayed incorrectly
Output:
fix(reports): correct date formatting in timezone conversion

Use UTC timestamps consistently across report generation
```

Examples help Claude understand desired style and detail level more clearly than descriptions alone.

## Domain-Specific Intelligence Pattern

For skills that add specialized knowledge beyond tool access:

```markdown
## Before Processing (Compliance Check)
1. Fetch transaction details
2. Apply compliance rules:
   - Check sanctions lists
   - Verify jurisdiction allowances
   - Assess risk level
3. Document compliance decision

## Processing
IF compliance passed:
  - Call payment processing MCP tool
  - Apply fraud checks
ELSE:
  - Flag for review
  - Create compliance case
```

Key techniques: domain expertise embedded in logic, compliance before action, comprehensive documentation.
