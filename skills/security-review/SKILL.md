---
name: security-review
description: "Run a security review against code changes or files. Covers OWASP Top 10: secrets management, input validation, SQL injection, XSS, CSRF, auth/authz, rate limiting, and sensitive data exposure. Use when adding auth, handling user input, creating API endpoints, working with secrets, implementing payments, or integrating third-party APIs. Triggers: 'security review', 'check for vulnerabilities', 'audit this endpoint', 'is this safe'. Do NOT use for general code review, performance optimization, or UI/UX feedback."
allowed-tools: [Read, Bash, Grep, Glob, WebSearch]
---

# Security Review

Audit code for vulnerabilities. Report each finding with: location (file:line), severity (CRITICAL/HIGH/MEDIUM/LOW), description, and fix.

## Review Order (by priority)

1. **Secrets** -- No hardcoded keys, tokens, or passwords. All secrets in env vars. `.env*` in `.gitignore`.
2. **Input validation** -- All user input validated with Zod schemas. File uploads restricted (size, type, extension). No direct use of user input in queries.
3. **SQL injection** -- All queries parameterized. No string concatenation in SQL.
4. **Auth/Authz** -- Tokens in httpOnly cookies (not localStorage). Authorization checks before sensitive operations. RBAC enforced.
5. **XSS** -- User HTML sanitized with DOMPurify. CSP headers configured. No unvalidated `dangerouslySetInnerHTML`.
6. **CSRF** -- CSRF tokens on state-changing operations. `SameSite=Strict` on cookies.
7. **Rate limiting** -- All API endpoints rate-limited. Stricter limits on expensive operations (search, AI generation).
8. **Data exposure** -- No secrets in logs. Generic error messages for users. No stack traces exposed.
9. **Dependencies** -- `npm audit` clean. Lock files committed.

## Quick Checks

```
# Hardcoded secrets
grep -rn "sk-\|password\s*=\s*[\"']" --include="*.ts" --include="*.tsx" src/

# Missing input validation
grep -rn "req\.body\|req\.query\|req\.params" --include="*.ts" src/app/api/ | grep -v "parse\|validate\|schema"

# SQL concatenation
grep -rn "SELECT.*\${\|INSERT.*\${\|UPDATE.*\${\|DELETE.*\${" --include="*.ts" src/

# localStorage tokens
grep -rn "localStorage.*token\|localStorage.*key" --include="*.ts" --include="*.tsx" src/
```

## Pre-Deployment Checklist

- [ ] No hardcoded secrets
- [ ] All inputs validated
- [ ] All queries parameterized
- [ ] XSS: user content sanitized, CSP configured
- [ ] CSRF protection enabled
- [ ] Auth: httpOnly cookies, RBAC enforced
- [ ] Rate limiting on all endpoints
- [ ] HTTPS enforced
- [ ] Security headers set (CSP, X-Frame-Options, X-Content-Type-Options)
- [ ] No sensitive data in logs or error responses
- [ ] Dependencies audited, lock files committed
- [ ] CORS properly configured
- [ ] File uploads validated

## Error Handling

- If a finding has no clear fix (e.g., third-party library vulnerability with no patch), report it with severity and recommend mitigation (pin version, add wrapper, monitor advisory).
- If the codebase uses patterns not covered here, flag them as "NEEDS MANUAL REVIEW" with the reason.
- If no vulnerabilities are found, explicitly state "No issues found" with the scope of the review (files examined, checks performed).

## References

See `references/code-examples.md` for detailed code patterns (secrets, validation, auth, XSS, CSRF, rate limiting, blockchain).
