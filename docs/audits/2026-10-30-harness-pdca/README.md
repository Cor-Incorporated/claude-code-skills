# Harness friction inventory — 2026-10-30 night (9 lanes)

- Measured: 2026-10-30 02:15–03:45 JST; deploy and follow-ups 05:13–11:5x JST, MacBook (teradakousuke), session harness-pdca
- Sources: plugin audit files `<project>/.claude/state/audit/guardrail-fires.jsonl` (ts ≥ 2026-10-29T15:00Z = 00:00 JST),
  Claude Code transcripts under `~/.claude/projects/*/*.jsonl` (tool_result paired with its tool_use command),
  lane reports in `~/Documents/Codex/2026-10-29/desktop-handoffs/completed/`
- Branch: `fix/harness-pdca-20261030` (claude-code-skills)

## Inventory

| # | Friction | Source | Class | Impact (tonight) | Evidence | Status |
|---|---|---|---|---|---|---|
| F1 | `RUNTIME_FLOOR:secret-read` on values-free files | harness plugin 5.16.0 `go/internal/runtimefloor/runtimefloor.go` `checkSecretRead` (indicator `credentials`, `.env`) | false positive | orchestrator ×3 (16:18Z, 16:22Z, 17:00Z), local-llm ×1 | transcript pairs below; `cat docs/templates/nas-mounts/smb-credentials.cred.template` → deny | **proposal (not shipped)**: review found that with `*.template` allowed the plugin also lets a real secret glued to an allowed name with `;`/`>` through (whitespace-only tokenizer). Declared `enforced=false` in `config/runtime-floor-allowlist.json` with the false positives and the compositions asserted against the real binary (#446); tokenizer fix added to the upstream patch |
| F1′ | `~/.ssh/config` grep denied | same | **true positive** | local-llm, NAS, coastal-link | `grep -E '^Host ' ~/.ssh/config` → deny | kept (must_deny) |
| F2 | `RUNTIME_FLOOR:egress` on cluster hosts and local copies | plugin `checkEgress`: `isAllowlistedHost` hardcodes localhost/127.0.0.1; `nc` takes the token after `nc` (a flag) as host; scp/rsync scan matches any `word.tld` in the whole command (`CLAUDE.md`, `fetch-models.sh`, a python module name, heredoc text) | false positive 6 / true positive 2 (pypi, github) → **FP rate 75 %** | NAS lane: Mac→NAS SMB check impossible (report §結論); physical-ai: scp to jetson-thor ×2; cor-voice: local rsync; ai-cluster 10-29 22:47 curl LAN | `nc -z -G 3 127.0.0.1 22` is denied (flag `-z` read as host); probe table below | **proposal**: upstream patch `upstream-runtime-floor.patch` (+21 Go cases, `go test ./internal/runtimefloor/` ok). Not deployable: third-party. Blanket `HARNESS_RUNTIME_FLOOR_EGRESS=off` rejected (inherited by child codex) → HP-1/HP-4 |
| F2′ | egress **false negatives** | same `remoteHostPattern` needs a letter TLD | hole | — | `scp ./build deploy@203.0.113.7:/srv/` and `rsync -a ./out/ 198.51.100.4:/srv/out/` are **allowed** | in the same upstream patch |
| F3 | floor fires absent from the ADR-006 ledger | plugin writes only its own audit file; deny fires no PostToolUseFailure (measured) | ledger gap | guard-ledger had 0 floor rows; 6/9 lanes fired | per-project counts below | **proposal (held back)**: `hooks/harness-guardrail-ledger.sh` + `aidd_ledger_append_records` in #445; adds the 30th registration, which the deploy condition forbade. Verified on a real audit file with a scratch ledger (9 → 10 rows on one deliberate hit) |
| F4 | `[recovery-guide]` misguidance | `hooks/tool-failure-recovery.sh` phrase-anywhere matching | wrong advice | every grep/rg miss, zsh missing commands | before/after table below | **fixed, deployed** #447 (exit code + anchored lines; only path-like text echoed) |
| F5 | formatter rewrote unedited lines | `hooks/post-lint-format.sh` ran `ruff format`/`--fix`/`gofumpt -w`/`golangci-lint --fix` unconditionally | data-destroying | 10-29 ai-cluster `test_judge_f64.py` (git checkout + redo); reproduced live tonight on a scratch .py | old hook: `test_judge.py | 14 +++---` with no ruff config | **fixed, deployed** #448 (project config + HEAD-clean gate, cached HEAD copy, skip rows in the ledger) |
| F6 | codex MCP `CONNECTION_CLOSED` | user-scope `~/.claude.json` mcpServers.codex = `codex mcp-server`; codex-cli 0.165.0 has no `mcp-server` subcommand (it is taken as a prompt) | config drift | Codex MCP unusable in every session (CLI `codex exec` unaffected) | `codex --help` subcommand list; `codex mcp-server --help` prints the top-level help | **human gate**: `claude mcp remove codex -s user` (delegation.md already forbids the MCP route) → HP-6 |
| F7 | handover packages heavy and pathless | briefs 45–47 KB each, `common-clauses.md` (8 KB) inside 37 brief files; no lane → repo path | usability | 10-29: 3 lanes stopped with zero edits | `wc -c` of `pending/Claude_Code依頼_20261029_*.md` | **fixed, deployed** #450 (lane manifest + validator + 禁止事項標準枠 HP-1..6). Weight reduction left as proposal |
| F8 | auto-broadcast on every .md/.sh/.go write | plugin `go/internal/hookhandler/session_auto_broadcast.go` (`autoBroadcastExtensions`); memory exclusion is `/.claude/memory/`, Claude Code memory lives at `~/.claude/projects/*/memory/` | noise + path leak across sessions | ai-cluster shared `broadcast.md`: ~40 entries tonight, 43 memory-path entries overall; corsweb 27, grift-cli 30 | `grep -c` on each repo's `.claude/sessions/broadcast.md` | **proposal**: per-repo `.claude/sessions/auto-broadcast.json {"enabled": false}` (owner decision; changes running lanes) and upstream: exclude `/.claude/projects/*/memory/` |
| F9 | `post-deploy-verify` fired on heredoc text | `hooks/post-deploy-verify.sh` `grep -q 'gcloud run deploy'` over the whole command | false positive | this session ×3 | test table | **fixed, deployed** #449 (recall first: heredoc bodies not run by a shell and quoted grep/echo text are ignored; python failure fails toward the checklist) |
| F10 | settings.json enabled a plugin id that is not installed | repo `claude-code-harness@…` vs installed `harness@…`; `setup.sh` overwrites the live file | latent outage | next `setup.sh` would have removed the floor and R01–R13 | `test-runtime-floor-allowlist.sh` L4 red on origin/develop | **fixed, deployed** #446 + `scripts/check-plugin-ids.py` (setup.sh refuses a drift that would turn off an installed, live-enabled plugin) |
| F11 | `RUNTIME_FLOOR:worktree-escape` on container paths | plugin `checkWorktreeEscape` sees `rm -rf /r/...` inside `docker run … sh -c` | false positive | grift-cli ×2 | transcript 17:08Z/17:09Z | reported only (upstream) |
| F12 | stale "files touched by other sessions" context | plugin PreToolUse:Write context (115–219 days old entries) | noise | every Write/Edit in this session | hook additional context | reported only |
| F13 | R01 no-sudo denies on the word in text | plugin R01 | false positive | this session ×2 (a python heredoc editing a README that mentioned a sudo flag; adding this very row) | hook output "sudo is not allowed" | reported only; long text goes to a file via Write |
| F14 | `setup.sh` stops at step 5 | `~/.codex/hooks.json` (mtime 10-28 15:04) has `CODEX_H1_MAX_ITERATIONS=100 bash …/h1-stall-runtime.sh`; `scripts/register-codex-h1-hooks.py` only accepts `bash <path>` | deploy blocker (manual config drift) | every setup.sh since 10-28 stops after copying hooks; steps 6–9 (Cursor/OpenCode/Pi hooks, scripts, pruning, OpenCode permissions, third-party) did not run | `setup-20261030.log` last line "Codex H1 registration failed: PreToolUse must contain exactly one protect hook and one H1 hook" | **human gate**: either drop the env prefix from `~/.codex/hooks.json` or teach the registrar env-prefixed commands (aidd-governance#228 decides the H1 limit) |
| F15 | async-work `check_cmd` pointed at a glob that matches nothing | written by **harness-pdca** (this lane) when declaring owners, not by the multinode lane: guessed `…ai-cluster--worktrees-claude-multinode-macless/*/scratchpad`; real `…-Developer-ai-cluster/0edeca5b-…/scratchpad` | wrong evidence pointer | the owner would run a command that prints "no matches found" | orchestrator 11:38 | **fixed** (dry-run before registering); proposal: `register` dry-runs `--check-cmd` once |
| F16 | `enforce-hook-deploy-after-merge.sh` reports a deploy that did not happen | (a) `git pull --ff-only 2>/dev/null` failure only warns, (b) copies from a stale checkout (`CLAUDE_PROJECT_DIR`, behind 24), (c) md5 compares src with dst, (d) ledger `pr=447/448/449 deployed=N failed=0` | false success | live hooks stayed 10-25 content until setup.sh at 11:37 | `guard-ledger.jsonl` hook-auto-deploy rows 20:13:29Z / 20:45:37Z / 20:57:30Z vs live sha = old develop | **proposal**: skip and log decision=skip when the pull fails; compare dst with `git show origin/develop:hooks/<f>` |
| F17 | H17 Readback check misses writes made through `~`, a shell variable, or a heredoc append | aidd_cc Readback matcher compares literal paths | false block | orchestrator's stop report blocked until the file was touched by absolute path (06:52:38); also `cat >> "/abs/報告.md" <<EOF … EOF` blocked at 11:39 and passed after `printf '' >> "/abs/報告.md"` at 11:41 — only the `printf '' >>` form is seen | orchestrator transcript | **proposal**: expand `~`/`$HOME`, or limit the check to Write/Edit paths and absolute Bash paths and say so in the error |
| F18 | a setup.sh deploy leaves no ledger row | setup.sh has no `aidd_ledger_append` | ledger gap | tonight's real deploy (11:37) is invisible in guard-ledger | last hook-auto-deploy row is pr=449 20:57:30Z | **proposal**: one `setup-deploy` row with hook count and the deployed sha |
| F19 | unattended lanes stop for hours at a permission prompt | 8 of 9 lanes started in default permission mode; a Bash call outside the allowlist waits for a person. The orchestrator may not act for a waiting session; the lane itself cannot see that it is waiting | silent stall | ~5 h (harness-pdca: after the #449 merge 05:57 → 11:36, when 寺田 switched the lanes to bypassPermissions) | orchestrator 06:35–06:52 list_events (last event = Bash call, no result) | **proposal**: (a) the lane launch contract states the permission policy and ships a pre-generated allowlist for the lane's own commands (fewer-permission-prompts), never bypass by default; (b) a `Notification` hook (fires when Claude waits for permission) appends one ledger row with session id and tool, so the orchestrator sees "waiting for permission since T" without acting for the lane; (c) the lane report's progress log gets that row automatically |
| F20 | `async-work.sh register` on a resolved id silently re-opens it under the caller | `scripts/async-work.sh` register: an unresolved old row keeps its session, a resolved one becomes a new row of the caller | data loss | harness-pdca re-opened 5 multinode rows at 11:41 that the orchestrator had resolved at 06:49, wiping the conclusions | state files 11:41, orchestrator resolve commands 21:49Z | **repaired** at 11:44 (original conclusions restored with attribution); proposal: refuse without `--reopen` |
| F21 | turn-boundary stop makes an unrelated session babysit another lane's async rows | `aidd-turn-boundary-stop.sh` foreign TTL 2 h blocks every session's stop | interruption | harness-pdca was stopped 6 times for multinode/local-llm rows it could not judge | Stop hook feedback in this transcript | **proposal**: block only the registering session, or a named owner session, after the TTL |

## Tonight's floor fires by worktree (plugin audit, ts ≥ 00:00 JST)

| worktree | fires |
|---|---|
| ai-cluster/.worktrees/claude/nas-24tb-secure-ai-ops | egress 2, secret-read 1, R01 2, R04 3, R05 2 |
| ai-cluster/.worktrees/claude/local-llm-single-device | secret-read 1 |
| ai-cluster/.worktrees/claude/multinode-macless | R05 2 |
| engineai-thor-sidecar/.worktrees/claude/post-visit-1219 | egress 2 |
| grift-cli/.worktrees/claude/until-1101-grift-cli | worktree-escape 2, R13 10, R05 12, R04 1 |
| corsweb/.worktrees/claude/cor-voice-harness | R02 6, R05 3, R04 1 |
| m02-smart-glasses | R04 19 |
| corsweb (main checkout) | egress 1, R03 1, R02 1, R05 2 |
| wind-speed-monitor/.claude/worktrees/coastal-link-… | secret-read 2, egress 1, R04 66, R05 5, R02 3 |

## Egress probe (plugin 5.16.0 binary, `bin/harness hook pre-tool`)

| command | 5.16.0 | patched |
|---|---|---|
| `nc -z -G 3 127.0.0.1 22` | deny (`nc -z`) | allow |
| `nc -z -G 3 -w 3 192.168.11.23 445` | deny (`nc -z`) | deny without allowlist / allow with `192.168.11.0/24` |
| `rsync -a --delete ./snap-before/ ./snap-after/ && cp CLAUDE.md x/` | deny (`CLAUDE.md`) | allow |
| `scp scripts/e2e/run.sh jetson-thor:ets/ && ssh jetson-thor 'python -m engineai_thor_sidecar.cli run'` | deny (module name) | deny without allowlist / allow with `jetson-thor` |
| `curl -s http://192.168.11.28:4000/health` | deny | allow with `192.168.11.0/24` |
| `scp ./build deploy@203.0.113.7:/srv/` | **allow** | deny |
| `rsync -a ./out/ 198.51.100.4:/srv/out/` | **allow** | deny |
| `curl -s https://pypi.org/pypi/awscrt/json` | deny | deny (with the cluster allowlist too) |

## tool-failure-recovery before / after (same input)

| case | before | after |
|---|---|---|
| grep exit 1, output quotes "command not found" | コマンド 'foo' が見つかりません | (silent) |
| `zsh: command not found: foo` | コマンド 'zsh' が見つかりません | コマンド 'foo' が見つかりません (exit 127) |
| `(eval):1: === not found` | (silent) | zsh の = 展開 |
| rg exit 2, one path missing, matches printed | ファイル/ディレクトリが存在しません | 存在しないパス: nope。検索自体は実行済み |
| ssh `Permission denied (publickey)` | 権限エラー … chmod +x | SSH 認証の失敗 |
| exit 126 | 権限エラー | 実行権限がありません |
| pytest `test_timeout_retry` failed | タイムアウト | (silent) |

## Deploy (2026-10-30 11:37:13 JST)

- #446–#450 merged into develop with `--merge` (05:13–05:57 JST), then `git pull --ff-only && bash setup.sh` in the shared checkout at 11:37 (05:57–11:36 this session waited at a Bash permission prompt after the #449 merge, see F19; 寺田 switched the lanes to bypassPermissions at 11:36).
- pre/post sha256: 49 → 51 files; changed exactly: `hooks/tool-failure-recovery.sh` 84485678→6a5bc99d, `hooks/post-lint-format.sh` f783d94c→8781b63e, `hooks/post-deploy-verify.sh` 5529c209→13739f50, `settings.json` 1bb87ed3→042298f6, `rules/quality.md`, `skills/handover/` (+2 files). Registrations 29, hard blocks 4, unchanged.
- canary (Bash `true`, Edit of a scratch .py: left as edited, two `autofix-skipped:no-project-config` rows), `tests/test-cross-tool-force-matrix.sh` holes 0 / false positives 0, new hook errors in transcripts since 02:37:13Z: 0. Orchestrator verified independently at 11:37 (25 hooks = origin/develop ac1fa58).

## Human gates

1. Merge this PR, then `setup.sh` on develop (deploy rule: develop only). Verify afterwards with
   `bash tests/test-runtime-floor-allowlist.sh` and one deliberate floor hit (the bridge test shows the row shape).
2. File the upstream patch to Chachamaru127/claude-code-harness (external repository).
3. `claude mcp remove codex -s user` (F6).
4. Decide F8: `.claude/sessions/auto-broadcast.json` `{"enabled": false}` per repo, or keep.
5. Decide the egress floor's fate under ADR-006 rule 6 (FP rate 75 % > 50 %) — see aidd-governance ADR-014 (Proposed).
