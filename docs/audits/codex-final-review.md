# Claude Code Skills Production Readiness Audit

Date: 2026-03-23

Scope:
- Read `README.md`
- Read all files under `hooks/` including `hooks/_unused/`
- Read `settings.json`
- Read all files under `rules/`
- Cross-checked against Claude Code Hooks reference: https://code.claude.com/docs/en/hooks

Key doc clauses used:
- Matchers are only supported on specific events; `Stop`/`TaskCompleted` do not support matchers.
- `Stop` and `SubagentStop` hooks should check `stop_hook_active` to avoid infinite continue loops.
- JSON output is only processed on exit `0`; on exit `2`, stdout JSON is ignored.
- `Stop`/`SubagentStop` use top-level `decision: "block"` + `reason`.
- `PostToolUseFailure` provides `error` and optional `is_interrupt`.
- `TaskCompleted` can block completion; `PostToolUseFailure` cannot block and is context-only.

## CRITICAL

### 1. Merge gate is self-bypassable through unprotected state writes
Status: `CRITICAL`

Evidence:
- The repo forbids direct writes to gate state files: `rules/delegation.md:23-38`.
- `hooks/pr-merge-claude-review-gate.sh:122`, `hooks/pr-merge-claude-review-gate.sh:146`, and `hooks/pr-merge-claude-review-gate.sh:196` explicitly instruct writing `pr-review-read.json` with `python3 -c ... json.dump(...)` to mark fallback review done, review read, and critical acknowledged.
- `hooks/block-state-file-tampering.sh:24-31` and `hooks/block-state-file-tampering-bash.sh:15` do not protect `pr-review-read.json`.

Impact:
- The gate intended to prove review was read and critical findings were acknowledged can be satisfied by writing the state file directly.
- This is the same class of self-bypass the repo says must never happen.

Verdict:
- Merge/readiness blocking defect.

## HIGH

### 2. Stop hooks do not guard on `stop_hook_active`
Status: `HIGH`

Evidence:
- Docs require checking `stop_hook_active` for `Stop`/`SubagentStop` to avoid indefinite continuation.
- `settings.json:517-531` registers two `Stop` hooks.
- `hooks/pr-ci-review-gate.sh:462-505` never reads `stop_hook_active`.
- `hooks/stop-test-gate.sh:1-105` never reads hook input beyond git/test detection and never checks `stop_hook_active`.

Impact:
- A blocked stop can immediately retrigger the same stop hook logic and loop.
- Production sessions can get stuck in repeated “continue” cycles.

### 3. `stop-test-gate.sh` uses the wrong Stop-hook control model
Status: `HIGH`

Evidence:
- Docs state JSON is only processed on exit `0`; exit `2` ignores stdout JSON.
- Docs state `Stop` uses top-level `decision`/`reason`.
- `hooks/stop-test-gate.sh:76-101` prints `hookSpecificOutput` JSON to stdout and exits `2`.

Impact:
- The hook may still block stopping because of exit `2`, but its structured JSON message is ignored.
- Users/Claude do not reliably get the intended reason/context.

### 4. Tiered review enforcement is inconsistent and undercuts FULL review
Status: `HIGH`

Evidence:
- README promises content-based `FULL/LIGHT/EXEMPT`: `README.md:216-236`.
- `hooks/pr-ci-review-gate.sh:92-100` hardcodes any `claude-code-skills` repo to `LIGHT`, regardless of changed files.
- `hooks/block-merge-without-review.sh:44-57` uses a different classifier and never computes file-based `LIGHT` for normal repos; it is effectively `EXEMPT` or `FULL`, except for the repo special case.

Impact:
- Executable hook and Python changes in this repository never require the advertised FULL-tier Codex second opinion.
- For other repos, docs/config-only changes can be misclassified as FULL in one gate and LIGHT in another.

### 5. State-file tamper protection misses the actual factcheck state file
Status: `HIGH`

Evidence:
- Factcheck state actually lives at `factcheck-status.json`: `hooks/reset-factcheck.sh:6-8`, `hooks/mark-factcheck-done.sh:6-40`, `hooks/enforce-factcheck-before-edit.sh:13-18`.
- Tamper guards protect `factcheck-state.json` instead: `hooks/block-state-file-tampering.sh:28`, `hooks/block-state-file-tampering-bash.sh:15`.

Impact:
- The real factcheck state can be edited directly without triggering the anti-bypass hooks.
- The enforced factcheck policy is not integrity-protected.

## MEDIUM

### 6. `TaskCompleted` safeguards are missing entirely
Status: `MEDIUM`

Evidence:
- `settings.json:52-534` registers `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop` only.
- No `TaskCompleted` hook is registered.

Impact:
- A task can be marked completed before the `Stop` gates run, even if PR review/CI state is still unresolved.

### 7. `PostToolUseFailure` coverage is missing entirely
Status: `MEDIUM`

Evidence:
- No `PostToolUseFailure` hook is registered in `settings.json:52-534`.

Impact:
- Failed `gh`, review-fetch, or verification commands do not attach corrective context or reconcile state.
- The repo relies heavily on GitHub state, so silent failure paths remain under-specified.

### 8. `post-deploy-verify.sh` emits invalid PostToolUse JSON
Status: `MEDIUM`

Evidence:
- For `PostToolUse`, docs require `hookSpecificOutput.hookEventName = "PostToolUse"` for `additionalContext`.
- `hooks/post-deploy-verify.sh:55-60` emits only:
  - `{ "additionalContext": "..." }`

Impact:
- The deployment checklist is unlikely to be injected into Claude’s context.
- The repo thinks it is enforcing post-deploy verification when it probably is not.

### 9. Context7 does not actually satisfy the factcheck flag despite repo guidance
Status: `MEDIUM`

Evidence:
- `hooks/mark-factcheck-done.sh:14-17` knows how to mark Context7 tool names.
- But `settings.json:371-388` only registers `mark-factcheck-done.sh` for `WebSearch|WebFetch` and `Read`.
- `hooks/enforce-factcheck-before-edit.sh:71` tells users to use Context7 to satisfy the gate.

Impact:
- The documented “use Context7 before editing” path does not work unless some other registered tool also fires.
- Users can follow the guidance and still remain blocked.

### 10. Post-lint quality loop is not macOS-compatible
Status: `MEDIUM`

Evidence:
- `hooks/post-lint-format.sh:33-37` unconditionally shells through `timeout`.
- Stock macOS does not provide `timeout`.
- By contrast, `hooks/stop-test-gate.sh:58-72` already contains an explicit macOS fallback.

Impact:
- On a default macOS machine, the post-lint hook silently degrades and does not enforce the intended loop.

### 11. Shared state updates are not consistently locked
Status: `MEDIUM`

Evidence:
- Some scripts use `fcntl.flock`, for example `hooks/pr-ci-review-gate.sh:389-405` and `hooks/context-budget-edit-write-gate.sh:199-214`.
- Others write shared state without locking, for example:
  - `hooks/record-code-review.sh:74-121`
  - `hooks/mark-factcheck-done.sh:36-39`
  - `hooks/codex-task-gate.sh:29-52`
  - `hooks/codex-task-release.sh:42-54`
  - `hooks/track-agent-team.sh:24-49`

Impact:
- Concurrent hook executions can lose updates or revert counters/flags.
- This is a real race-condition risk because hooks can fire rapidly around agent/tool activity.

### 12. Codex MCP is allowed by permissions and blocked only by hook
Status: `MEDIUM`

Evidence:
- `settings.json:17-21` allows `mcp__codex__codex`.
- The policy says Codex MCP is forbidden: `rules/delegation.md:40-44`.
- Enforcement depends on the hook at `settings.json:359-367` and `hooks/block-codex-mcp.sh:1-30`.

Impact:
- Defense in depth is weak. If hooks are disabled/mis-scoped, the permission layer still permits the forbidden path.

## PASS

### 13. Hook registrations point to real hook files
Status: `PASS`

Evidence:
- No dangling `~/.claude/hooks/...` references were found in `settings.json`.
- Directly registered hook files exist under `hooks/`.
- Non-registered files observed (`inject-claude-review-helper.py`, `record-codex-review.sh`) are helper/manual-entry scripts, not broken registrations.

### 14. Event/matcher basics are mostly spec-compliant
Status: `PASS`

Evidence:
- Registered events are valid Claude Code events.
- `Stop` is configured without a matcher: `settings.json:517-531`.
- `PreToolUse` and `PostToolUse` matchers are tool-name regexes, which is the documented matcher model.

### 15. Codex MCP blocking exists at hook level
Status: `PASS`

Evidence:
- `settings.json:359-367` registers a `PreToolUse` matcher for `mcp__codex__.*`.
- `hooks/block-codex-mcp.sh:18-30` exits `2`, which is the documented blocking behavior for `PreToolUse`.

## Overall Verdict

`BLOCK`

Reason:
- The repository is not production-ready in its current form because a merge/readiness gate is self-bypassable, Stop hooks are not implemented to spec, and the advertised review-tier/state-protection model is not internally consistent.
