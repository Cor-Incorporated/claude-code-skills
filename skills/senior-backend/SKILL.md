---
name: senior-backend
description: "Guides backend system development with Node.js, Express, Go, Python, PostgreSQL, GraphQL, and REST APIs. Use when the user says: 'design an API', 'optimize database queries', 'implement authentication', 'set up backend', 'create API endpoint', 'database migration', 'fix N+1 query', 'add rate limiting', 'backend code review'. Covers API scaffolding, database optimization, security implementation, and performance tuning. Do NOT use for frontend/UI work (use senior-fullstack), test writing (use tdd-workflow), or changelog generation."
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebSearch]
---

# Senior Backend

Guide backend development with focus on API design, database optimization, and security.

## Core Workflow

### 1. Scaffold an API

Generate API boilerplate with best practices:

```bash
python scripts/api_scaffolder.py <project-path> [options]
```

### 2. Manage Database Migrations

Run the migration tool for schema changes:

```bash
python scripts/database_migration_tool.py <target-path> [--verbose]
```

### 3. Load Test APIs

Verify performance under load:

```bash
python scripts/api_load_tester.py [--analyze]
```

## Reference Documentation

Consult before implementing:

- `references/api_design_patterns.md` -- REST/GraphQL patterns, versioning, error responses
- `references/database_optimization_guide.md` -- indexing, N+1 prevention, query tuning
- `references/backend_security_practices.md` -- auth, CORS, rate limiting, injection prevention

## Key Principles

- **Parameterized queries**: Never concatenate user input into SQL
- **Input validation**: Use Zod schemas for all API request bodies
- **Error responses**: Return consistent error format with status code, message, and error code
- **Auth checks**: Verify user ownership on every data access (`WHERE userId = ?`)
- **Idempotency**: Design mutations to be safely retryable (especially webhooks)

## API Design Checklist

1. Define Zod schema for request/response
2. Implement route handler with proper HTTP methods
3. Add authentication middleware
4. Add authorization check (ownership/role)
5. Validate input, execute logic, return typed response
6. Add error handling with appropriate status codes
7. Write integration test

## Database Optimization Checklist

- Add indexes for frequently queried columns
- Use `SELECT` only needed columns (avoid `SELECT *`)
- Prevent N+1 with eager loading (`include`/`join`)
- Use connection pooling in production
- Add `EXPLAIN ANALYZE` for slow queries

## Error Handling

- If migration fails: check database connection string and run `npx prisma migrate status`
- If load test shows high latency: check `references/database_optimization_guide.md` for indexing strategies
- If API scaffolder errors: verify Python 3.8+ and required templates exist in scripts/
- If auth fails: verify JWT_SECRET is set and token expiry is configured
- Always validate webhook signatures before processing payloads
