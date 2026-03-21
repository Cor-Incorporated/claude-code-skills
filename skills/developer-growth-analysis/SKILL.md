---
name: developer-growth-analysis
description: "Analyze Claude Code chat history to identify coding patterns, skill gaps, and growth areas. Generates a personalized report with curated HackerNews learning resources and sends it to Slack DMs. Triggers: 'analyze my growth', 'review my coding patterns', 'developer growth report', 'what should I learn', 'analyze my recent work'. Do NOT use for code review, project analysis, or team performance evaluation."
allowed-tools: [Read, Bash, Grep, WebFetch]
---

# Developer Growth Analysis

Analyze recent Claude Code chat history, identify improvement areas, curate learning resources, and deliver a growth report to Slack DMs.

## Steps

<important if="reading and parsing Claude Code chat history for growth analysis">
### 1. Read Chat History

Read `~/.claude/history.jsonl` (JSONL format). Each line contains:
- `display`: User's message
- `project`: Project name
- `timestamp`: Unix timestamp (ms)
- `pastedContents`: Pasted code/content

Filter for entries from the past 24-48 hours.
</important>

<important if="analyzing developer work patterns from chat history">
### 2. Analyze Work Patterns

Extract from filtered chats:
- **Projects/Domains**: backend, frontend, DevOps, data, etc.
- **Technologies**: languages, frameworks, tools used
- **Problem Types**: debugging, feature implementation, refactoring, optimization
- **Challenges**: repeated questions, multi-attempt problems, knowledge gaps
- **Approach Patterns**: methodical, exploratory, experimental
</important>

<important if="identifying skill gaps and improvement areas from coding patterns">
### 3. Identify 3-5 Improvement Areas

Each area must be:
- **Specific**: not "improve coding skills" but "Advanced TypeScript generics for type-safe API responses"
- **Evidence-based**: grounded in actual chat history
- **Actionable**: practical steps to improve
- **Prioritized**: most impactful first
</important>

<important if="generating the developer growth report document">
### 4. Generate Report

Structure the report as:

```markdown
# Your Developer Growth Report
**Report Period**: [Date Range]
**Last Updated**: [Current Date]

## Work Summary
[2-3 paragraphs: projects, technologies, focus areas]

## Improvement Areas (Prioritized)
### 1. [Area Name]
**Why This Matters**: [Importance]
**What I Observed**: [Evidence from chat history]
**Recommendation**: [Concrete steps]
**Time to Skill Up**: [Effort estimate]
---
[Repeat for 2-4 more areas]

## Strengths Observed
[2-3 bullet points of things to continue]

## Action Items
1. [Highest priority action]
2. [Next action]
3. [Next action]

## Curated Learning Resources
[Populated in next step]
```
</important>

<important if="searching HackerNews for curated learning resources">
### 5. Search Learning Resources

Use HackerNews search for each improvement area:
- Query: "[Technology/Pattern] best practices", "[Topic] advanced techniques"
- Select 2-3 high-engagement articles per area
- Include: title, date, relevance description, link
</important>

<important if="sending growth report to Slack DMs">
### 6. Send to Slack DMs

- Check Slack connection via RUBE_SEARCH_TOOLS.
- If not connected, use RUBE_MANAGE_CONNECTIONS to initiate auth.
- Send report in logical sections using RUBE_MULTI_EXECUTE_TOOL.
- Confirm delivery.
</important>

<important if="handling errors during growth analysis execution">
## Error Handling

- If `~/.claude/history.jsonl` does not exist or is empty, inform the user and suggest running some Claude Code sessions first.
- If no entries found in 24-48 hours, expand the window to 7 days.
- If Slack connection fails, output the report directly in the terminal as fallback.
- If HackerNews search returns no results for an area, note it and suggest alternative search terms.
</important>
