# Claude Code Skills — Canonical State (ADR-006)

- Declared: 2026-08-09
- Source of truth branch for deploy: **develop**
- Related: ADR-006 minimal safety net, Issue #130 hook deploy integrity, aidd-governance R-S0

## Hook registration (canonical)

| Item | Value |
|---|---|
| Registered hooks in `settings.json` | **22** (ADR-006 base + H3 Stop evidence warn + dns-self-heal SessionStart + async-work 持ち越し 2 本) |
| Events | 6 (SessionStart / PreToolUse / PostToolUse / PostToolUseFailure / PreCompact / Stop) |
| Hard-block PreToolUse | **4** (`git-push-guard`, `protect-branches`, `block-local-hooks-write`, plus SessionStart `validate-no-local-hooks`) |
| Turn-boundary block (Stop) | **1** (`aidd-turn-boundary-stop.sh` — 未完了の非同期作業を残したままターンを終えさせない。PreToolUse ではないので上の hard-block 4 には数えない。aidd-governance#96 / #95) |
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

## Branch policy — `main` is frozen

`develop` is the single source of truth and the repository's default branch.
**`main` is a frozen archive. Do not sync `develop` into it.**

2026-09-02 実測:

| | `develop` | `main` |
|---|---|---|
| Total files | 299 | 127 |
| `hooks/` | 96 | **0**（意図的に削除済み） |
| Release tags | — | **0** |
| Default branch | **yes** | no |
| Last updated | 継続中 | 2026-08-12 |

`main` を薄くしたのは事故ではなく設計判断である:

- `fc7aa3e chore(hooks): remove hooks/ from main (loop-break T4; SSOT is develop)`
- `1d6ea0f fix(setup): add branch guard to main's setup.sh (T12-2 CC-D3)`

`main` にしか存在しないファイル 31 件は**全て develop で退役済み**であり、
救出対象は無い（`changelog-generator` / `git-commit-helper` → `git-conventions`、
`senior-{architect,backend,frontend,fullstack}` → `dev-guidelines`、
`scripts/verify-pr-review.sh` → `check-pr-reviews.sh` / `classify-review-state.sh`）。

### なぜ同期してはいけないか

`develop` → `main` の同期は、意図的に空にした `hooks/` 96 本を含む
**+28,056 行**を `main` に戻す。これは上表 "Non-canonical states" の
「`main` で `setup.sh` を走らせると ADR-006 が巻き戻る」に直結する。

PR #280「chore: sync develop into main」は 2026-09-02 にこの理由で close した。
**同種の PR を再度作らないこと。**

### `main` を再び使いたくなったら

その時点で「何のために使うか」を先に決める。リリース tag も deploy 経路も
現在は `main` を参照していないので、用途が無いまま同期だけ行う理由は無い。

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
