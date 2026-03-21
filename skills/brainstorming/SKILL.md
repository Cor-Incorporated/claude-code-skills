---
name: brainstorming
description: "Explore ideas and design solutions collaboratively before implementation. Use BEFORE building features, components, or making architectural changes. Triggers: 'brainstorm', 'design this feature', 'let's think through', 'explore approaches', 'before we build', 'what should we consider'. Do NOT use for implementation, code review, or bug fixes."
allowed-tools: [Read, Grep, Glob, WebSearch, AskUserQuestion]
---

# Brainstorming Ideas Into Designs

Turn ideas into validated designs through structured collaborative dialogue before writing any code.

## Process

### 1. Understand Context

- Read project state: files, docs, recent commits.
- Ask **one question at a time** to refine the idea.
- Prefer multiple-choice questions over open-ended ones.
- Focus on: purpose, constraints, success criteria.

### 2. Explore Approaches

- Propose 2-3 approaches with trade-offs.
- Lead with your recommended option and explain why.
- Apply YAGNI ruthlessly -- remove unnecessary features.

### 3. Present Design Incrementally

- Break design into sections of 200-300 words.
- Ask after each section: "Does this look right so far?"
- Cover: architecture, components, data flow, error handling, testing.
- Go back and clarify when something does not make sense.

### 4. Document

- Write validated design to `docs/plans/YYYY-MM-DD-<topic>-design.md`.
- Commit the design document.

### 5. Transition to Implementation (Optional)

- Ask: "Ready to set up for implementation?"
- Create isolated workspace with git worktree if proceeding.
- Draft a detailed implementation plan.

## Error Handling

- If project context is unclear, ask for the repository path or relevant files before proceeding.
- If the user provides conflicting requirements, surface the conflict explicitly and ask for resolution.
- If a design section is rejected, revise that section before moving to the next.

## Key Principles

- **One question at a time** -- do not overwhelm.
- **Multiple choice preferred** -- easier to answer.
- **YAGNI ruthlessly** -- cut unnecessary scope.
- **Explore alternatives** -- always compare 2-3 approaches.
- **Incremental validation** -- present in sections, confirm each.
