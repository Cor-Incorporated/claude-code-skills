---
name: senior-fullstack
description: "Guides fullstack web application development with React, Next.js, Node.js, GraphQL, and PostgreSQL. Use when the user says: 'scaffold a new project', 'set up fullstack app', 'analyze code quality', 'review architecture', 'create project structure', 'implement design pattern', 'fullstack development help'. Covers project scaffolding, code quality analysis, architecture patterns, and tech stack guidance. Do NOT use for backend-only tasks (use senior-backend), test writing (use tdd-workflow), or file organization (use file-organizer)."
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebSearch]
---

# Senior Fullstack

Guide fullstack development using modern tools and established patterns.

## Core Workflow

### 1. Scaffold a Project

Run the fullstack scaffolder to generate project structure:

```bash
python scripts/fullstack_scaffolder.py <project-path> [options]
```

Use the project scaffolder for analysis and optimization:

```bash
python scripts/project_scaffolder.py <target-path> [--verbose]
```

### 2. Analyze Code Quality

Run the analyzer to detect issues and get recommendations:

```bash
python scripts/code_quality_analyzer.py [--analyze]
```

### 3. Apply Architecture Patterns

Consult reference docs before implementing:

- `references/tech_stack_guide.md` -- patterns, examples, anti-patterns
- `references/architecture_patterns.md` -- workflows, optimization, troubleshooting
- `references/development_workflows.md` -- integrations, security, scalability

## Tech Stack

| Layer | Technologies |
|-------|-------------|
| Languages | TypeScript, JavaScript, Python, Go |
| Frontend | React, Next.js, React Native |
| Backend | Node.js, Express, GraphQL, REST |
| Database | PostgreSQL, Prisma, Supabase |
| DevOps | Docker, Kubernetes, Terraform, GitHub Actions |
| Cloud | AWS, GCP, Azure |

## Key Principles

- **Immutability**: Return new objects, never mutate (`{ ...obj, key: value }`)
- **Validation**: Use Zod for input validation, parameterized queries for SQL
- **Structure**: Functions under 50 lines, files under 800 lines, nesting under 4 levels
- **Security**: No hardcoded secrets, server-side API calls only, proper auth checks

## Common Commands

```bash
npm run dev          # Start dev server
npm run build        # Production build
npm test             # Run tests
npm run lint         # Lint code
docker build -t app:latest .   # Build container
```

## Error Handling

- If scaffolder fails: verify Python 3.8+ is installed and scripts/ directory exists
- If quality analyzer reports issues: fix CRITICAL/HIGH first, then MEDIUM
- If build fails after scaffolding: check `package.json` dependencies and `.env` configuration
- Always run `npm run type-check` before committing changes
