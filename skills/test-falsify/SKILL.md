---
name: test-falsify
description: "Verify that tests actually detect the bugs they claim to detect. Checks if assertions would fail when the declared bug exists -- catches 'tests that pass even when broken' (PR #321 incident). Invoke with /test-falsify or auto-trigger after E2E/integration test creation. Use when: reviewing test quality, validating regression tests, reporting test results in PRs, or when a test seems too permissive. Do NOT use for: unit test generation, test coverage analysis, performance benchmarking, or linting."
allowed-tools: [Read, Bash, Grep, Glob]
---

# Test Falsifiability Verifier

Verify that tests fail when their declared bugs exist. A test that passes with the bug present is worthless.

## When to Run

- After creating/modifying E2E or integration tests
- Before reporting test results in a PR
- When `/test-falsify` is explicitly invoked
- When a test looks suspiciously permissive

## Execution

### Phase 1: Extract Intent

From the target test file, extract:

1. **Bug declarations**: keywords `Bug`, `detect`, `regression`, `fix` in docstrings/comments.
2. **Test name intent**: `test_long_conversation_natural_ending` -> validates "natural ending".
3. **User requirements**: check conversation history for the original test request.

<important if="reviewing test quality or validating whether assertions catch the declared bug">
### Phase 2: Analyze Assertions

Evaluate each assertion against three checks:

**Check 1: Falsifiability (CRITICAL)**

> Would this assertion fail if the declared bug exists?

| Pattern | Verdict | Example |
|---------|---------|---------|
| Bug present -> assertion fails | VALID | `assert turn_count != 37` |
| Bug present -> might pass | WEAK | `assert turn_count >= 18` (37 >= 18 passes) |
| Bug present -> always passes | INVALID | `assert result.completed` (completes at 37 too) |

**Check 2: Uniformity Detection**

> Does the test verify that different inputs produce different outputs?

| Pattern | Verdict |
|---------|---------|
| Multiple inputs + variance check | VALID |
| Single input + lower bound only | INVALID |
| Parametrize + per-case lower bound | WEAK (uniform results still pass) |

**Check 3: Domain Consistency**

> Do test results contradict domain common sense?

Refer to `references/domain-checklist.md` for domain-specific checks.
</important>

<important if="improving weak or invalid test assertions">
### Phase 3: Propose Improvements

Provide concrete assertion additions:

```python
# Variance check: different answers produce different turn counts
results = [run(verbose_answers), run(brief_answers), run(mixed_answers)]
turn_counts = [r.turn_count for r in results]
assert max(turn_counts) - min(turn_counts) >= 3, "Fixed turn count = ignoring answers"

# Upper bound: reject known-bad fixed value
assert result.turn_count < 35, "37-turn fixed pattern detected"

# Uniformity rejection: not all models produce identical results
followup_counts = [r.followup_count for r in model_results]
assert len(set(followup_counts)) > 1, "All models identical = mechanical"

# Domain-specific: detailed answers should end sooner
verbose = run(very_detailed_answers)
brief = run(minimal_answers)
assert verbose.turn_count < brief.turn_count, "Not evaluating answer quality"
```
</important>

<important if="generating a falsifiability review report for a PR or test audit">
### Phase 4: Report

```markdown
## Falsifiability Review

### Target: `path/to/test_file.py`

### Intent-Assertion Alignment
| # | Declared Intent | Assertion | Fails with bug? | Verdict |
|---|----------------|-----------|-----------------|---------|
| 1 | Bug 3: 37-turn fix | turn_count >= 18 | No (37>=18) | INVALID |
| 2 | Natural ending | has_farewell() | Yes | WEAK |

### Uniformity Check
- Multiple input patterns: YES / **NO**
- Variance verification: YES / **NO**

### Domain Consistency
- [Any domain-specific anomalies]

### Recommended Fixes
1. [Specific assertion to add]
2. [Test case to add]
```
</important>

<important if="encountering edge cases during falsifiability analysis">
## Error Handling

| Situation | Action |
|-----------|--------|
| No docstring/comment declaring intent | Infer from test name; flag as "intent undocumented" |
| Cannot determine if bug makes assertion fail | Run mental simulation with bug present; if uncertain, mark WEAK |
| All assertions are INVALID | Recommend rewrite with concrete examples; do not approve |
| Test has no assertions | Flag as INVALID -- assertion-free test proves nothing |
</important>

## References

- `references/domain-checklist.md` -- Domain-specific test consistency checks
