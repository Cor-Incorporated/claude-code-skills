// DeepSeek Harness (dsh) NATIVE cordis plugin for the H17 common control (aidd-governance#179).
//
// Why a native plugin: the shipped bridge `@deepseek-ai/dsh-hooks-claude-code` maps `Stop` onto
// `agent/turn-stopping` but its Stop payload has no `last_assistant_message` and an empty
// `transcript_path` (bridge README "Known Limitations", measured live 2026-10-14 05:11Z: the Stop hook
// fired, the oracle saw an empty text and allowed 「実装完了しました。」).  The session itself holds the
// text: the decoded `session.v4.jsonl.zstd` of that run has `assistant/message` (seq 20) BEFORE the
// `hook/invoked Stop` rows (seq 22-27), so a plugin on the same extension point can read it from
// `agent.session.events` and hand it to the shared oracle (~/.claude/hooks/lib/aidd_cc.py, agent `dsh`).
//
// Extension points used (same as the bridge, lib/index.js of dsh-hooks-claude-code@0.0.1-rc.5):
//   agent/pre-step        -> prompt            (user decisions / deadline)
//   tools/pre-execute     -> pre               (C-ITER; PreToolDecision.deny)
//   tools/post-execute    -> post              (rc from `result.value.exitCode`, marker fallback; output for evidence)
//   agent/turn-stopping   -> stop              (C-EVIDENCE; agent.steer() with the gate reason, max 2 per turn;
//                                               a released claim's note goes to stderr, never into the inbox)
// tests/test-dsh-native-driver.sh drives these handlers with a fake agent (no dsh, no API key).
//
// Install (experiment profile only, never the default one):
//   copy next to cordis.patch.yml and add to the patch layer:
//     - insert:
//         - id: aidd-cc-native
//           name: ./aidd-cc-native.mts
//           config: { oracle: !!js `${process.env.HOME}/.claude/hooks/lib/aidd_cc.py` }
//
// STATUS 2026-10-18: live with DEEPSEEK_API_KEY (owner terminal): pre/post rows recorded, bash tool ran; the stop
// handler read `session.events` (not a field) and returned silently → fixed to `session.log` + an H6 error row on
// empty text. Install: dsh 0.2.0-rc.1 ONLY, with npm overrides pinning dsh-tools / dsh-agent to 0.2.0-rc.1 — the
// rc.5 Claude-Code bridge hoists older copies and the bash tool dies with "reading 'prepare'" (runbook §2).
// STATUS 2026-10-17: LOADS on dsh 0.2.0-rc.1 (node 24.21.0, `--experimental-strip-types` implied by .mts):
// `dsh --profile headless --patch dsh/aidd-cc.patch.yml` activates this entry (no "did not activate" warning) and
// stops only at MISSING_CREDENTIAL for the LLM — the live Stop block still needs a DEEPSEEK_API_KEY run by the
// owner (`bw-secrets run DEEPSEEK_API_KEY=DEEPSEEK_API_KEY -- dsh …`). Install: `npm i @deepseek-ai/dsh@0.2.0-rc.1
// @deepseek-ai/dsh-hooks-claude-code@0.0.1-rc.5` in a scratch prefix (0.2.0-rc.2 pulls the npm-restricted
// @deepseek-ai/dsh-bash-env and does not install). tests/test-dsh-native-plugin.sh checks the activation.
// The .ts form failed to import ("set type: module or use .mjs"); .mts is what node loads here.
// STATUS 2026-10-16: UNVERIFIED on a live dsh.  The dsh core packages are `publishConfig.access:
// restricted` and the dependency `@deepseek-ai/dsh-bash-env@^0.0.1-rc.1` returns npm 404 on this
// machine, so this file type-checks only against the API shapes visible in the bridge's compiled
// lib/index.js (ctx.on / agent.session.events / agent.steer / createUserMessage / PreToolDecision).
// It is the design + skeleton the owner's dsh checkout can run; #179 stays BLOCKED_EXTERNAL until a
// live Stop block is measured through it.
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createUserMessage } from "@deepseek-ai/dsh-llm";

export const name = "aidd-cc-native";
export const inject: string[] = [];

export interface Config {
  /** Path to the shared oracle (default: ~/.claude/hooks/lib/aidd_cc.py). */
  oracle?: string;
  /** Max forced continuations per turn before the unverified claim is let through WITH a visible note. */
  maxSteers?: number;
}

type Verdict = { decision?: string; reason?: string; rule?: string; would_block?: boolean; note?: string };
const AGENT = "dsh";

function ledgerError(rule: string, detail: string): void {
  const ledger = process.env.AIDD_LEDGER_PATH ?? join(homedir(), ".claude", "hooks", "ledger", "guard-ledger.jsonl");
  const row = {
    ts: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    component: "H17", hook: "aidd-cc", event: "error", decision: "unavailable", rule,
    cmd_head: detail.slice(0, 120), source: process.env.AIDD_LEDGER_SOURCE ?? "real", session: "unset", agent: AGENT,
  };
  try {
    mkdirSync(dirname(ledger), { recursive: true });
    appendFileSync(ledger, JSON.stringify(row) + "\n");
  } catch {
    /* the ledger itself is unavailable */
  }
}

export function runCC(oracle: string, cmd: string, payload: Record<string, unknown>, extra: string[] = []): Promise<Verdict> {
  if (process.env.AIDD_CC_DISABLE === "1") return Promise.resolve({ decision: "allow", rule: "disabled" });
  return new Promise((resolve) => {
    const child = spawn("python3", ["-I", oracle, cmd, "--agent", AGENT, ...extra], {
      env: { ...process.env, AIDD_CC_AGENT: AGENT },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += String(d)));
    child.on("error", (e) => {
      ledgerError(`spawn-error:${cmd}`, String(e));
      resolve({ decision: "allow", rule: "spawn-error" });
    });
    child.on("close", (code) => {
      const line = out.trim().split("\n").pop() ?? "";
      if (!line) {
        ledgerError(`python-exit-${code}:${cmd}`, "");
        resolve({ decision: "allow", rule: "empty" });
        return;
      }
      try {
        resolve(JSON.parse(line) as Verdict);
      } catch (e) {
        ledgerError(`parse-error:${cmd}`, String(e));
        resolve({ decision: "allow", rule: "parse-error" });
      }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

/** Text parts of a dsh message (content blocks; reasoning blocks are not the report). */
function blocksToText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => (b && typeof b === "object" && (b as { type?: string }).type === "text" ? String((b as { text?: string }).text ?? "") : ""))
    .join("");
}

/** The last `assistant/message` of the current turn from the session event log. */
function lastAssistantText(agent: any): string {
  // dsh 0.2.0-rc.1: the session keeps its event log in `session.log` (seq-ordered `{type, data}` events, the same
  // shape as session.v4.jsonl); `events` was never a field — the live run of 2026-10-18 20:00 JST read nothing.
  const session = agent?.session;
  const events: any[] = [...(session?.log ?? session?.events ?? [])];
  const turnStart = events.findLast((e) => e?.type === "turn/start");
  const turn = turnStart?.data?.turn;
  const msg = events.findLast((e) => e?.type === "assistant/message" && (turn === undefined || e?.data?.turn === turn));
  return blocksToText(msg?.data?.message?.content);
}

/**
 * Exit status of a dsh tool result (ccs#421). dsh-tool-bash@0.2.0-rc.1 `renderResult` appends `[exit code: N]` only
 * when N != 0, so a clean run had no marker and every success was recorded `rc: null` (owner live run 2026-10-19:
 * the gate answered "exit status unavailable is UNKNOWN" to an honest Evidence trailer). The structured value of a
 * finished foreground run carries it: `result.value = { kind: "foreground", exitCode: number | null, … }`.
 * The text markers stay as the fallback (dsh-tool-bash-persistent writes `[Command finished with exit code N]`).
 * A background / promoted call has no exit status yet → undefined (UNKNOWN, never assumed 0).
 */
export function exitCodeOf(result: any, text: string): number | undefined {
  const code = result?.value?.exitCode;
  if (Number.isInteger(code)) return code;
  const m = /\[(?:exit code:|Command finished with exit code) (-?\d{1,3})\]\s*$/.exec(text.trim());
  return m ? Number(m[1]) : undefined;
}

// Head + tail, never the head alone: the status line (`X; echo exit=$?`) and test summaries are the LAST lines, and
// a head-only cut let a failing X's early `exit=0` stand in for the echo's `exit=1` (ADR-011, Codex review P2).
const clipOut = (s: string, n = 4000): string => (s.length <= n ? s : `${s.slice(0, n / 2)}\n…\n${s.slice(-n / 2)}`);

// Session format v4 wants a producer-owned source kind (the generic "plugin" is rejected: `format v4 message requires
// a producer-owned source kind`, live 2026-10-18 20:11 JST); dsh's own bridges use `{ kind: "hooks-codex" }`.
const AIDD_SOURCE = { kind: "aidd-cc" };

export function apply(ctx: any, config: Config = {}): void {
  const oracle = config.oracle ?? join(homedir(), ".claude", "hooks", "lib", "aidd_cc.py");
  const maxSteers = config.maxSteers ?? 2;
  const steers = new Map<string, number>(); // session id -> steers in the current turn

  ctx.on("agent/pre-step", async ({ agent, messages }: any, next: () => Promise<any>) => {
    const sid = String(agent?.session?.header?.id ?? "unset");
    const user = [...(messages ?? [])].reverse().find((m: any) => m?.role === "user" && m?.source?.kind === "user");
    const prompt = blocksToText(user?.content);
    if (prompt && !prompt.trimStart().startsWith("[H17 evidence gate]")) {
      steers.delete(sid); // a new user request gets a fresh gate budget
      await runCC(oracle, "prompt", { session_id: sid, prompt, cwd: agent?.session?.header?.cwd });
    }
    return next();
  });

  ctx.on("tools/pre-execute", async (exec: any, next: () => Promise<any>) => {
    const sid = String(exec?.agent?.session?.header?.id ?? "unset");
    const v = await runCC(oracle, "pre", {
      session_id: sid, tool_name: exec?.name, tool_input: exec?.arguments ?? {}, cwd: exec?.agent?.session?.header?.cwd,
    });
    if (v.decision === "block") return { kind: "deny", reason: `[H17] ${v.reason ?? v.rule}` };
    return next();
  });

  ctx.on("tools/post-execute", async (exec: any, result: any, next: () => Promise<any>) => {
    const sid = String(exec?.agent?.session?.header?.id ?? "unset");
    const text = clipOut(blocksToText(result?.content));
    // dsh renders stdout, then `[stderr]`, then markers: a failing X's stderr `exit=0` would land after the echo's
    // stdout `exit=1`. The structured streams go separately so the oracle reads the status from stdout (ADR-011).
    const v = result?.value;
    // `truncated`: the executor cut STDOUT (where the echo writes), so the echo's line may be gone — the oracle then
    // keeps UNKNOWN; a cut stderr says nothing about it (Codex review r3 P2)
    const streams = typeof v?.stdout?.text === "string"
      ? { stdout: clipOut(v.stdout.text), stderr: clipOut(String(v?.stderr?.text ?? "")),
          truncated: v.stdout.truncated === true }
      : { output: text };
    await runCC(oracle, "post", {
      session_id: sid, tool_name: exec?.name, tool_input: exec?.arguments ?? {},
      tool_response: { exit_code: exitCodeOf(result, text), ...streams }, cwd: exec?.agent?.session?.header?.cwd,
    });
    return next();
  });

  ctx.on("agent/turn-stopping", async ({ agent }: any) => {
    const sid = String(agent?.session?.header?.id ?? "unset");
    const text = lastAssistantText(agent);
    if (!text.trim()) {
      // never a silent pass (#186 P2-2): the stop ran but found no assistant text — visible as an H6 error row
      ledgerError("stop-no-assistant-text", `session=${sid} log=${(agent?.session?.log ?? []).length}`);
      return;
    }
    const n = steers.get(sid) ?? 0;
    const extra = n >= maxSteers ? ["--max-blocks", "0", "--no-count"] : [];
    const v = await runCC(oracle, "stop", { session_id: sid, last_assistant_message: text, cwd: agent?.session?.header?.cwd }, extra);
    const note = v.decision === "block"
      ? `[H17 evidence gate] ${v.reason ?? ""} — fix the report before claiming completion.`
      : v.would_block ? `${v.note ?? "[H17] evidence unverified (max-blocks released)"} — ${v.reason ?? ""}` : null;
    if (!note) return;
    if (v.decision === "block" && n < maxSteers) {
      steers.set(sid, n + 1);
      agent.steer(createUserMessage({ content: [{ type: "text", text: note }], source: AIDD_SOURCE }));
      return;
    }
    // Budget spent or python released: the claim passes WITH a visible note (never silently, #186 P1-4) — but the
    // note must not start a model turn. `agent.inject()` queues model-facing context that the running driver claims
    // at the next step boundary, so at turn-stopping it re-opened the turn: the owner's live run of 2026-10-19
    // 12:49:53Z-12:50:10Z answered the same note 4 times (4 `evidence.max-blocks.would-block` rows for agent dsh).
    // dsh 0.2.0-rc.1 has no display-only message (its own Claude Code bridge drops `systemMessage`: "not yet
    // surfaced"), so the note goes to stderr like the Pi headless entry; the would-block row written by aidd_cc.py
    // is the durable H6 record. Never route it through steer / inject / followup / send.
    process.stderr.write(`${note}\n`);
  });
}

export default apply;
