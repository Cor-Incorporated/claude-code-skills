---
name: senior-frontend
description: "Build high-performance web applications with React, Next.js, TypeScript, and Tailwind CSS. Use for frontend feature development, component creation, performance optimization, bundle analysis, UI/UX implementation, state management, and frontend code review. Triggers: 'create component', 'optimize performance', 'reduce bundle size', 'fix UI', 'frontend review', 'React pattern', 'Next.js optimization'. Do NOT use for backend-only tasks, database design, or infrastructure/DevOps work."
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebSearch]
---

# Senior Frontend

Build production-grade frontend applications following modern patterns and best practices.

## Core Tools

```bash
# Generate React component with tests and types
python scripts/component_generator.py <project-path> [options]

# Analyze bundle size and get optimization recommendations
python scripts/bundle_analyzer.py <target-path> [--verbose]

# Scaffold frontend project structure
python scripts/frontend_scaffolder.py [arguments] [options]
```

## Workflow

### 1. Analyze Before Building

```bash
python scripts/bundle_analyzer.py .
```

Review output for: large dependencies, unused code, optimization opportunities.

### 2. Implement Following Patterns

Consult these references in order of relevance:

- `references/react_patterns.md` -- Component composition, hooks, state management, anti-patterns
- `references/nextjs_optimization_guide.md` -- SSR/SSG, image optimization, code splitting, caching
- `references/frontend_best_practices.md` -- TypeScript patterns, testing, security, accessibility

### 3. Generate Components

```bash
python scripts/component_generator.py <project-path> [options]
```

Ensure generated components include: TypeScript types, tests, proper imports.

### 4. Verify Quality

```bash
npm run lint && npm run type-check && npm test
```

## Key Practices

- **Performance:** Measure first with `bundle_analyzer.py`, then optimize critical paths. Use `React.memo`, `useMemo`, `useCallback` only when profiling shows a need.
- **Code splitting:** Use `next/dynamic` for heavy components, route-based splitting by default.
- **State management:** Prefer React Context + hooks for simple state, Zustand/Jotai for complex state.
- **Accessibility:** Semantic HTML, ARIA labels, keyboard navigation, color contrast.
- **Testing:** Unit tests for logic, integration tests for user flows, visual regression for UI.

## Error Handling

- If `bundle_analyzer.py` fails, verify `node_modules` exists: run `npm install` first.
- If `component_generator.py` produces incorrect templates, check project's `tsconfig.json` for path aliases.
- If type errors appear after generation, verify the project's TypeScript version matches template expectations.

## References

- `references/react_patterns.md` -- Patterns, anti-patterns, real-world scenarios
- `references/nextjs_optimization_guide.md` -- Performance tuning, troubleshooting
- `references/frontend_best_practices.md` -- Security, scalability, integration patterns
- `scripts/` -- Component generator, bundle analyzer, scaffolder
