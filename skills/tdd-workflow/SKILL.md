---
name: tdd-workflow
description: "Enforces test-driven development with 80%+ coverage across unit, integration, and E2E tests. Use when the user says: 'write tests first', 'TDD', 'add test coverage', 'test this feature', 'write unit tests', 'create integration test', 'add E2E test', 'fix with TDD', 'red green refactor', 'increase coverage'. Guides the RED-GREEN-REFACTOR cycle for new features, bug fixes, and refactoring. Do NOT use for running existing tests without changes, CI/CD pipeline setup, or code review without test focus."
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob]
---

# TDD Workflow

Enforce test-driven development: write tests first, implement to pass, then refactor.

<important if="writing new tests or implementing a new feature with TDD">
## The Cycle: RED -> GREEN -> REFACTOR

### RED: Write Failing Tests

Define expected behavior before writing any implementation:

```typescript
describe('searchMarkets', () => {
  it('returns relevant markets for query', async () => {
    const results = await searchMarkets('election')
    expect(results).toHaveLength(5)
    expect(results[0].relevanceScore).toBeGreaterThan(0.8)
  })

  it('returns empty array for no matches', async () => {
    const results = await searchMarkets('zzz_nonexistent')
    expect(results).toEqual([])
  })

  it('handles empty query gracefully', async () => {
    const results = await searchMarkets('')
    expect(results).toEqual([])
  })
})
```

Run tests -- they MUST fail:
```bash
npm test -- --run [test-file]
```

### GREEN: Write Minimal Implementation

Write just enough code to make all tests pass. No more.

```bash
npm test -- --run [test-file]
# All tests should now pass
```

### REFACTOR: Improve While Green

Improve code quality with tests as safety net:
- Remove duplication
- Improve naming
- Optimize performance
- Extract helpers

Run tests after each change to confirm nothing broke.
</important>

<important if="choosing which test type to write or classifying existing tests">
## Test Types and When to Use

| Type | What to Test | Tool | Speed Target |
|------|-------------|------|-------------|
| Unit | Single function/class, pure logic | Vitest/Jest | < 50ms each |
| Integration | API endpoints, DB operations, service interactions | Vitest + mocks | < 500ms each |
| E2E | Critical user flows through browser | Playwright | < 30s each |

**IMPORTANT**: curl tests are integration tests, NOT E2E. E2E requires browser verification.
</important>

<important if="measuring coverage or checking if coverage targets are met">
## Coverage Requirement

Target 80%+ across all metrics:

```bash
npm run test:coverage
```

Check branches, functions, lines, and statements individually.
</important>

<important if="writing new tests or refactoring existing tests">
## Testing Rules

1. **Test behavior, not implementation**
   - WRONG: `expect(component.state.count).toBe(5)`
   - RIGHT: `expect(screen.getByText('Count: 5')).toBeInTheDocument()`

2. **Each test is independent** -- set up own data, no shared mutable state

3. **Use semantic selectors**
   - WRONG: `page.click('.css-xyz')`
   - RIGHT: `page.click('[data-testid="submit"]')` or `page.click('button:has-text("Submit")')`

4. **Mock external dependencies** -- isolate the unit under test

5. **Test edge cases** -- null, undefined, empty, boundary values, error paths

6. **Arrange-Act-Assert** structure in every test
</important>

<important if="writing tests that need to mock databases or external APIs">
## Mocking Patterns

### Database/ORM
```typescript
vi.mock('@/lib/prisma', () => ({
  prisma: { user: { findUnique: vi.fn() } }
}))
```

### External APIs
```typescript
vi.mock('@/lib/external-api', () => ({
  fetchData: vi.fn(() => Promise.resolve({ data: 'mocked' }))
}))
```
</important>

<important if="debugging failing tests, flaky tests, or slow test suites">
## Error Handling

- If tests pass immediately (no RED phase): the test is not testing anything meaningful. Add assertions that verify specific behavior.
- If coverage is below 80%: run `npm run test:coverage` and check the uncovered lines report. Add tests for missed branches.
- If E2E tests are flaky: replace `waitForTimeout` with `waitForSelector` or `expect().toBeVisible()`. Never use fixed timeouts.
- If mocks leak between tests: add `vi.restoreAllMocks()` in `afterEach` or use `vi.mock` at module level.
- If tests are slow (unit > 50ms): check for unmocked network calls or missing test isolation.
</important>
