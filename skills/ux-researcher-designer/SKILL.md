---
name: ux-researcher-designer
description: "UX research and design toolkit: data-driven persona generation, journey mapping, usability testing frameworks, and research synthesis. Use when creating personas, mapping user journeys, planning usability tests, or synthesizing research findings. Triggers: 'create persona', 'map user journey', 'plan usability test', 'synthesize research'. Do NOT use for UI implementation, visual design, or coding tasks."
---

# UX Researcher & Designer

Generate research-backed UX artifacts from user data.

## Core Capabilities

- **Persona generation**: Analyze behavior patterns, identify archetypes, extract psychographics, generate scenarios, score confidence by sample size.
- **Journey mapping**: Map customer touchpoints, identify pain points, surface opportunities.
- **Usability testing**: Create test frameworks, define tasks, structure findings.
- **Research synthesis**: Aggregate insights across studies, prioritize by impact.

## Persona Generator

Run: `python scripts/persona_generator.py [json]`

Input: JSON with user behavior data and interview transcripts.
Output: Research-backed personas with design implications.

### Required Input Fields

- `users`: Array of user behavior records (sessions, actions, demographics).
- `interviews` (optional): Array of interview transcript summaries.

### Output Includes

- Persona archetype with name, demographics, goals, frustrations.
- Behavioral patterns and psychographic profile.
- Usage scenarios with design implications.
- Confidence score based on sample size (`low` < 10, `medium` 10-50, `high` > 50).

## Error Handling

- If input JSON is malformed, report the parse error with the expected schema.
- If sample size is below 5, warn that personas are speculative and flag confidence as `very low`.
- If no interview data is provided, note that psychographic depth is limited to behavioral inference only.
