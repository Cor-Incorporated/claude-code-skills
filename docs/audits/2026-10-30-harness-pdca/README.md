# Harness friction inventory — 2026-10-30 night (9 lanes)

- Measured: 2026-10-30 02:15–03:45 JST, MacBook (teradakousuke), session harness-pdca
- Sources: plugin audit files `<project>/.claude/state/audit/guardrail-fires.jsonl` (ts ≥ 2026-10-29T15:00Z = 00:00 JST),
  Claude Code transcripts under `~/.claude/projects/*/*.jsonl` (tool_result paired with its tool_use command),
  lane reports in `~/Documents/Codex/2026-10-29/desktop-handoffs/completed/`
- Branch: `fix/harness-pdca-20261030` (claude-code-skills)

## Inventory

| # | Friction | Source | Class | Impact (tonight) | Evidence | Status |
|---|---|---|---|---|---|---|
| F1 | `RUNTIME_FLOOR:secret-read` on values-free files | harness plugin 5.16.0 `go/internal/runtimefloor/runtimefloor.go` `checkSecretRead` (indicator `credentials`, `.env`) | false positive | orchestrator ×3 (16:18Z, 16:22Z, 17:00Z), local-llm ×1 | transcript pairs below; `cat docs/templates/nas-mounts/smb-credentials.cred.template` → deny | **fixed via plugin knob**: `config/runtime-floor-allowlist.json` → `settings.json env.HARNESS_RUNTIME_FLOOR_SECRET_ALLOW` (`*.template,.env.example,.env.sample`), linked to the real binary by `tests/test-runtime-floor-allowlist.sh`. Verb/indicator in different segments (`ls .env.example; grep …`) is an upstream bug → HP-2 |
| F1′ | `~/.ssh/config` grep denied | same | **true positive** | local-llm, NAS, coastal-link | `grep -E '^Host ' ~/.ssh/config` → deny | kept (must_deny) |
| F2 | `RUNTIME_FLOOR:egress` on cluster hosts and local copies | plugin `checkEgress`: `isAllowlistedHost` hardcodes localhost/127.0.0.1; `nc` takes the token after `nc` (a flag) as host; scp/rsync scan matches any `word.tld` in the whole command (`CLAUDE.md`, `fetch-models.sh`, a python module name, heredoc text) | false positive 6 / true positive 2 (pypi, github) → **FP rate 75 %** | NAS lane: Mac→NAS SMB check impossible (report §結論); physical-ai: scp to jetson-thor ×2; cor-voice: local rsync; ai-cluster 10-29 22:47 curl LAN | `nc -z -G 3 127.0.0.1 22` is denied (flag `-z` read as host); probe table below | **proposal**: upstream patch `upstream-runtime-floor.patch` (+21 Go cases, `go test ./internal/runtimefloor/` ok). Not deployable: third-party. Blanket `HARNESS_RUNTIME_FLOOR_EGRESS=off` rejected (inherited by child codex) → HP-1/HP-4 |
| F2′ | egress **false negatives** | same `remoteHostPattern` needs a letter TLD | hole | — | `scp ./build deploy@203.0.113.7:/srv/` and `rsync -a ./out/ 198.51.100.4:/srv/out/` are **allowed** | in the same upstream patch |
| F3 | floor fires absent from the ADR-006 ledger | plugin writes only its own audit file; deny fires no PostToolUseFailure (measured) | ledger gap | guard-ledger had 0 floor rows; 6/9 lanes fired | per-project counts below | **fixed**: `hooks/harness-guardrail-ledger.sh` (PostToolUse:Bash) + `aidd_ledger_append_records` |
| F4 | `[recovery-guide]` misguidance | `hooks/tool-failure-recovery.sh` phrase-anywhere matching | wrong advice | every grep/rg miss, zsh missing commands | before/after table below | **fixed** (exit code + anchored lines), 14 cases + in-test mutant |
| F5 | formatter rewrote unedited lines | `hooks/post-lint-format.sh` ran `ruff format`/`--fix`/`gofumpt -w`/`golangci-lint --fix` unconditionally | data-destroying | 10-29 ai-cluster `test_judge_f64.py` (git checkout + redo); reproduced live tonight on a scratch .py | old hook: `test_judge.py | 14 +++---` with no ruff config | **fixed** (project config + HEAD-clean gate; golangci report-only) |
| F6 | codex MCP `CONNECTION_CLOSED` | user-scope `~/.claude.json` mcpServers.codex = `codex mcp-server`; codex-cli 0.165.0 has no `mcp-server` subcommand (it is taken as a prompt) | config drift | Codex MCP unusable in every session (CLI `codex exec` unaffected) | `codex --help` subcommand list; `codex mcp-server --help` prints the top-level help | **human gate**: `claude mcp remove codex -s user` (delegation.md already forbids the MCP route) → HP-6 |
| F7 | handover packages heavy and pathless | briefs 45–47 KB each, `common-clauses.md` (8 KB) inside 37 brief files; no lane → repo path | usability | 10-29: 3 lanes stopped with zero edits | `wc -c` of `pending/Claude_Code依頼_20261029_*.md` | **fixed (minimal)**: `skills/handover/lane-manifest.template.yaml` + `validate-lane-manifest.py` + SKILL.md step 7. Weight reduction (reference + sha instead of paste) left as proposal — it changes the paste rule from #91 |
| F8 | auto-broadcast on every .md/.sh/.go write | plugin `go/internal/hookhandler/session_auto_broadcast.go` (`autoBroadcastExtensions`); memory exclusion is `/.claude/memory/`, Claude Code memory lives at `~/.claude/projects/*/memory/` | noise + path leak across sessions | ai-cluster shared `broadcast.md`: ~40 entries tonight, 43 memory-path entries overall; corsweb 27, grift-cli 30 | `grep -c` on each repo's `.claude/sessions/broadcast.md` | **proposal**: per-repo `.claude/sessions/auto-broadcast.json {"enabled": false}` (owner decision; changes running lanes) and upstream: exclude `/.claude/projects/*/memory/` |
| F9 | `post-deploy-verify` fired on heredoc text | `hooks/post-deploy-verify.sh` `grep -q 'gcloud run deploy'` over the whole command | false positive | this session ×3 | test table | **fixed** recall-first: the phrase counts anywhere except a heredoc body and the quoted text of grep/rg/echo/printf (a first command-position version missed `for … do docker push`, `sudo -E`, `bash -c`; caught in review). Literal `\n` in the checklist fixed |
| F10 | settings.json enabled a plugin id that is not installed | repo `claude-code-harness@…` vs installed `harness@…`; `setup.sh` overwrites the live file | latent outage | next `setup.sh` would have removed the floor and R01–R13 | `test-runtime-floor-allowlist.sh` L4 red on origin/develop | **fixed** + `scripts/check-plugin-ids.py` (setup.sh and L4): refuses a rename (same marketplace, one name contains the other), warns on a plugin simply missing here |
| F11 | `RUNTIME_FLOOR:worktree-escape` on container paths | plugin `checkWorktreeEscape` sees `rm -rf /r/...` inside `docker run … sh -c` | false positive | grift-cli ×2 | transcript 17:08Z/17:09Z | reported only (upstream) |
| F12 | stale "files touched by other sessions" context | plugin PreToolUse:Write context (115–219 days old entries) | noise | every Write/Edit in this session | hook additional context | reported only |

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

## Human gates

1. Merge this PR, then `setup.sh` on develop (deploy rule: develop only). Verify afterwards with
   `bash tests/test-runtime-floor-allowlist.sh` and one deliberate floor hit (the bridge test shows the row shape).
2. File the upstream patch to Chachamaru127/claude-code-harness (external repository).
3. `claude mcp remove codex -s user` (F6).
4. Decide F8: `.claude/sessions/auto-broadcast.json` `{"enabled": false}` per repo, or keep.
5. Decide the egress floor's fate under ADR-006 rule 6 (FP rate 75 % > 50 %) — see aidd-governance ADR-014 (Proposed).
