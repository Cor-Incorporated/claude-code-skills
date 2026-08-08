# Claude Code Skills — Canonical State (ADR-006)

- Declared: 2026-08-09
- Source of truth branch for deploy: **develop**
- Related: ADR-006 minimal safety net, Issue #130 hook deploy integrity, aidd-governance R-S0

## Hook registration (canonical)

| Item | Value |
|---|---|
| Registered hooks in `settings.json` | **19** (18 ADR-006 + H3 Stop evidence warn) |
| Events | 6 (SessionStart / PreToolUse / PostToolUse / PostToolUseFailure / PreCompact / Stop) |
| Hard-block PreToolUse | **4** (`git-push-guard`, `protect-branches`, `block-local-hooks-write`, plus SessionStart `validate-no-local-hooks`) |
| Deploy path | `setup.sh` copies hooks/rules/skills/settings from **this repo's current branch** into `~/.claude` |

### Hard blocks (tail-risk; keep)

1. `git-push-guard.sh` — force-push / protected-branch direct push
2. `protect-branches.sh` — protected branch workflow
3. `block-local-hooks-write.sh` — prevent AI self-bypass of hooks
4. `validate-no-local-hooks.sh` — SessionStart integrity

These are C14 tail-risk type: absence of catastrophe is passive proof. Ledger wiring (H6) is still required for fire observation.

## Non-canonical states (do not restore)

| State | Why invalid |
|---|---|
| `main` historical `settings.json` with ~63 registrations | Pre-ADR-006 peak; running `setup.sh` on main rewinds ADR-006 |
| Unregistered scripts only under `~/.claude/hooks/` | Deploy/reality drift (C12) |
| Regex-era large PreToolUse surface | ADR-006 retired to `_unused/` |

## Deploy rule

```text
setup.sh MUST be run only from branch develop.
Any other branch → refuse (exit 1).
```

## Admission fee for new hooks (P2 / hook-deployment 6 requirements)

1. Script exists under `hooks/`
2. Installed via `setup.sh` to `~/.claude/hooks/`
3. Registered in `settings.json` matcher/event
4. Defense ledger: one JSONL line on fire → `~/.claude/hooks/ledger/guard-ledger.jsonl`
5. Negative test: known-bad injection turns red; record attached to introducing PR
6. Retirement condition: 90 days zero fires or FP rate >50% → auto issue candidate (H6)

Without requirements 4–6, do not merge block-capable guards or completion verifiers.

## Inventory note

- `hooks/_unused/`: retired assets (history preserve; not deployed)
- Active shell hooks in repo `hooks/*.sh` should match develop settings registration set after prune
