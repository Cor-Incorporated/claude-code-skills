---
name: adk-engineer
description: "Implement production-ready agents using Google Agent Development Kit (ADK). Use when creating ADK agents, building multi-agent systems, implementing workflow agents, reviewing ADK code, or deploying to Vertex AI / Cloud Run. Triggers: 'ADK agent', 'Google ADK', 'multi-agent system', 'Gemini agent', 'agent workflow', 'adk deploy'. Do NOT use for non-ADK agent frameworks (LangChain, CrewAI, AutoGen) or general Gemini API calls without ADK."
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebFetch]
---

# ADK Engineer

Implement, review, and deploy Google ADK agents following proven patterns and best practices.

## Quick Start

**Single agent:** Read `references/adk-patterns.md` -> Use `assets/templates/single-agent/` -> Validate with `references/adk-best-practices.md`.

**Multi-agent system:** Choose pattern (Coordinator, Sequential, Parallel, Loop) -> Use matching template from `assets/templates/` -> Consult `references/adk-patterns.md`.

<important if="choosing an ADK agent pattern or designing a multi-agent system architecture">

## Pattern Selection

| Task Type | Pattern | Template |
|-----------|---------|----------|
| Linear data processing | Sequential Pipeline | `assets/templates/workflow/` |
| Intent-based routing | Coordinator/Dispatcher | `assets/templates/multi-agent/` |
| Independent concurrent tasks | Parallel Fan-Out/Gather | `assets/templates/workflow/` |
| Nested agent structures | Hierarchical Decomposition | `assets/templates/multi-agent/` |
| Validation loops | Generator-Critic | `assets/templates/workflow/` |
| Quality improvement | Iterative Refinement | `assets/templates/workflow/` |
| Critical decisions | Human-in-the-Loop | `assets/templates/single-agent/` |

</important>

## Implementation Workflow

<important if="creating a new ADK agent from a template">

### New Agent

1. **Choose pattern** from table above based on task analysis.
2. **Copy template:**
   ```bash
   cp -r assets/templates/[single-agent|multi-agent|workflow]/ ./my_agent/
   # Or: bash scripts/init_adk_project.sh my_agent [template_type]
   ```
3. **Implement domain logic:** Define custom tools, update instructions, configure `output_key` values.
4. **Test locally:** Run `python agent.py` or `adk ui`.
5. **Validate:**
   ```bash
   python scripts/validate_agent.py agent.py
   ```
6. **Deploy** per `references/adk-deployment.md`.

</important>

<important if="reviewing existing ADK agent code for correctness and best practices">

### Code Review

1. Read agent code and identify patterns used.
2. Check implementation against `references/adk-patterns.md`.
3. Review against `references/adk-best-practices.md`.
4. Run `python scripts/validate_agent.py agent.py`.
5. Provide specific, actionable recommendations with references.

</important>

<important if="validating an ADK agent before deployment or during code review">

## Validation Checklist

- [ ] `root_agent` properly defined
- [ ] Agent descriptions are clear and specific
- [ ] Descriptive `output_key` values for state management
- [ ] Loop agents have `max_iterations`
- [ ] Parallel agents use unique `output_key` values
- [ ] Tools follow verb-noun naming pattern
- [ ] Error handling with graceful degradation
- [ ] Appropriate model selection per agent complexity
- [ ] `REQUIRE_CONFIRMATION` for high-stakes operations

</important>

<important if="deploying an ADK agent to Vertex AI Agent Engine or Cloud Run">

## Deployment

```bash
# Vertex AI Agent Engine (recommended)
adk deploy agent_engine --project=PROJECT_ID --region=us-central1 \
  --staging_bucket=gs://BUCKET/staging --agent-file=agent.py

# Cloud Run
adk deploy cloud_run --project=PROJECT_ID --region=us-central1 \
  --agent-file=agent.py
```

See `references/adk-deployment.md` for Docker, CI/CD, monitoring, and security details.

</important>

## Error Handling

- If `validate_agent.py` reports issues, fix all CRITICAL/HIGH items before deployment.
- If pattern selection is ambiguous, default to Coordinator for routing tasks, Sequential for pipelines.
- If deployment fails, check project permissions and staging bucket access first.

## References

- `references/adk-patterns.md` -- 7 design patterns with code examples
- `references/adk-best-practices.md` -- Agent design, state management, tools, security
- `references/adk-deployment.md` -- Deployment workflows, CI/CD, monitoring, cost optimization
- `assets/templates/` -- Single-agent, multi-agent, workflow starter templates
- [Google ADK Docs](https://google.github.io/adk-docs/)
