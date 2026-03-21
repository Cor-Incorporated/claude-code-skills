---
name: senior-architect
description: "Design scalable, maintainable system architectures with technology stack decisions, dependency analysis, and architecture diagrams. Use for system design, architecture decisions, trade-off evaluation, integration patterns, and technical decision frameworks. Triggers: 'design the system', 'architecture for', 'how should we structure', 'tech stack decision', 'dependency analysis', 'draw architecture diagram', 'evaluate trade-offs'. Do NOT use for implementation details, frontend component creation, or code-level refactoring."
allowed-tools: [Read, Grep, Glob, Bash, WebSearch, AskUserQuestion]
---

# Senior Architect

Design scalable systems with architecture diagrams, technology decisions, and dependency analysis.

## Core Tools

```bash
# Generate architecture diagrams (Mermaid/PlantUML)
python scripts/architecture_diagram_generator.py <project-path> [options]

# Analyze project structure and recommend architecture improvements
python scripts/project_architect.py <target-path> [--verbose]

# Map and analyze project dependencies
python scripts/dependency_analyzer.py [arguments] [options]
```

## Workflow

<important if="analyzing current project structure, dependencies, or coupling metrics">
### 1. Analyze Current State

```bash
python scripts/project_architect.py .
python scripts/dependency_analyzer.py --analyze
```

Review: dependency graph, circular dependencies, coupling metrics, layer violations.
</important>

<important if="designing system architecture or evaluating architecture patterns">
### 2. Design Architecture

Consult references based on task:
- `references/architecture_patterns.md` -- Layered, hexagonal, microservices, event-driven, CQRS
- `references/system_design_workflows.md` -- Step-by-step design process, optimization strategies
- `references/tech_decision_guide.md` -- Stack selection criteria, comparison matrices, security considerations
</important>

<important if="generating architecture diagrams with Mermaid or PlantUML">
### 3. Generate Diagrams

```bash
python scripts/architecture_diagram_generator.py <project-path> [options]
```

Produce: system context, container, component, and sequence diagrams as needed.
</important>

<important if="documenting architecture decisions as ADRs">
### 4. Document Decisions

Record architecture decisions as ADRs (Architecture Decision Records):
- Context, decision, consequences, alternatives considered.
</important>

<important if="verifying architecture quality after design changes">
### 5. Verify Quality

```bash
python scripts/project_architect.py . --verbose
```

Check: no circular dependencies, proper layer separation, acceptable coupling metrics.
</important>

## Key Principles

- **Start with requirements**: Clarify functional and non-functional requirements before choosing patterns.
- **Trade-offs over dogma**: Every pattern has costs. Document what you gain and what you sacrifice.
- **Separation of concerns**: Enforce clear boundaries between layers and modules.
- **Design for change**: Prefer loose coupling and high cohesion to enable future evolution.
- **Validate with metrics**: Use `dependency_analyzer.py` output to verify coupling and cohesion.

<important if="handling errors from architecture analysis tools">
## Error Handling

- If `project_architect.py` fails, verify the project path exists and contains source code.
- If `dependency_analyzer.py` reports circular dependencies, prioritize breaking cycles before adding features.
- If architecture diagrams do not render, check Mermaid/PlantUML syntax and tool version.
</important>

<important if="looking up architecture reference materials or tool locations">
## References

- `references/architecture_patterns.md` -- Patterns, anti-patterns, real-world scenarios
- `references/system_design_workflows.md` -- Design processes, optimization, troubleshooting
- `references/tech_decision_guide.md` -- Stack selection, integration, security, scalability
- `scripts/` -- Diagram generator, project architect, dependency analyzer
</important>
