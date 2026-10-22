// OpenCode plugin entry for the H17 common control (AIDD).
// Deployed to ~/.config/opencode/plugins/aidd-cc.ts and listed in opencode.jsonc "plugin".
//
//   chat.message          -> prompt            (register user decisions / deadlines)
//   tool.execute.before   -> pre               (C-ITER; throws to block the call)
//   tool.execute.after    -> post              (record rc/output for evidence binding)
//   (permission.ask: retired 2026-10-14 — H17 never auto-allows; see hooks/lib/aidd_cc_controls.py)
//   event session.idle    -> stop              (C-EVIDENCE; re-prompts the session once)
//   process exit          -> stop              (headless `opencode run`: the last text part of each session that no
//                                               tool call followed is the final answer; ADR-009 Status is required
//                                               there, the verdict goes to stderr + the H6 ledger — review r2 P1)
//
// The verdict logic is python (hooks/lib/aidd_cc.py) shared with Claude/Codex/Cursor,
// so one oracle covers all four real entries.  Session key: sessionID.
import os from "os"
import path from "path"
import { appendFileSync, mkdirSync } from "fs"

const CC_PY = process.env.AIDD_CC_PY ?? path.join(os.homedir(), ".claude", "hooks", "lib", "aidd_cc.py")
const AGENT = "opencode"
// Head + tail, never the head alone: the status line (`X; echo exit=$?`) and test summaries are the LAST lines, and
// a head-only cut let a failing X's early `exit=0` stand in for the echo's `exit=1` (ADR-011, Codex review P2).
const clipOut = (s: string, n = 4000): string => (s.length <= n ? s : `${s.slice(0, n / 2)}\n…\n${s.slice(-n / 2)}`)
const MAX_REPROMPTS = 2

type Verdict = { decision?: string; reason?: string; rule?: string; problems?: string[] }

// aidd-governance#186 P2-2: a spawn / parse failure of the oracle is a visible degradation (H6 error row),
// never a silent allow.  Same row shape as aidd-cc-adapter.sh ledger_error().
function ledgerError(rule: string, detail: string): void {
  const ledger = process.env.AIDD_LEDGER_PATH ?? path.join(os.homedir(), ".claude", "hooks", "ledger", "guard-ledger.jsonl")
  const row = {
    ts: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    component: "H17", hook: "aidd-cc", event: "error", decision: "unavailable", rule,
    cmd_head: detail.slice(0, 120), source: process.env.AIDD_LEDGER_SOURCE ?? "real", session: "unset", agent: AGENT,
  }
  try {
    mkdirSync(path.dirname(ledger), { recursive: true })
    appendFileSync(ledger, JSON.stringify(row) + "\n")
  } catch {
    /* the ledger itself is unavailable: nothing else to write to */
  }
}

async function cc(cmd: string, payload: Record<string, unknown>, extra: string[] = []): Promise<Verdict> {
  if (process.env.AIDD_CC_DISABLE === "1") return { decision: "allow", rule: "disabled" }
  try {
    const proc = Bun.spawn(["python3", "-I", CC_PY, cmd, "--agent", AGENT, ...extra], {
      stdin: new TextEncoder().encode(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, AIDD_CC_AGENT: AGENT },
    })
    const out = await new Response(proc.stdout).text()
    await proc.exited
    const line = out.trim().split("\n").pop() ?? ""
    if (!line) {
      ledgerError(`python-exit-${proc.exitCode}:${cmd}`, "")
      return { decision: "allow", rule: "empty" }
    }
    return JSON.parse(line) as Verdict
  } catch (e) {
    ledgerError(`spawn-or-parse-error:${cmd}`, String(e))
    return { decision: "allow", rule: "error", reason: String(e) }
  }
}

// Synchronous twin of cc() for the process-exit path (an exit handler cannot await).
function ccSync(cmd: string, payload: Record<string, unknown>, extra: string[] = []): Verdict {
  if (process.env.AIDD_CC_DISABLE === "1") return { decision: "allow", rule: "disabled" }
  try {
    const proc = Bun.spawnSync(["python3", "-I", CC_PY, cmd, "--agent", AGENT, ...extra], {
      stdin: new TextEncoder().encode(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, AIDD_CC_AGENT: AGENT },
    })
    const line = new TextDecoder().decode(proc.stdout).trim().split("\n").pop() ?? ""
    if (!line) {
      ledgerError(`python-exit-${proc.exitCode}:${cmd}`, "")
      return { decision: "allow", rule: "empty" }
    }
    return JSON.parse(line) as Verdict
  } catch (e) {
    ledgerError(`spawn-or-parse-error:${cmd}`, String(e))
    return { decision: "allow", rule: "error", reason: String(e) }
  }
}

function textOf(parts: unknown): string {
  if (!Array.isArray(parts)) return ""
  return parts
    .map((p) => (p && typeof p === "object" && (p as { type?: string }).type === "text" ? String((p as { text?: string }).text ?? "") : ""))
    .join("\n")
}

export const AiddCommonControl = async ({ client }: { client: any }) => {
  const reprompts = new Map<string, number>()
  // ADR-009 (review r2 P1): the last text part of a session that no tool call followed is its final answer.
  // session.idle judges it in the TUI; headless `opencode run` exits before idle work lands, so the process
  // exit handler judges whatever is still here (Status required) — stderr line + H6 row, never silent.
  const lastPart = new Map<string, { messageID: string; text: string }>()
  process.once("exit", () => {
    for (const [sessionID, { text }] of lastPart) {
      const v = ccSync("stop", { sessionID, last_assistant_message: text }, ["--max-blocks", "99", "--no-count"])
      const line = v.decision === "block" ? `[H17 evidence gate] ${v.reason ?? ""}` : (v as { note?: string }).note
      if (line) process.stderr.write(`${line}\n`)
    }
    lastPart.clear()
  })
  return {
    "chat.message": async (
      input: { sessionID?: string },
      output: { message?: unknown; parts?: unknown },
    ) => {
      const text = textOf(output.parts)
      if (!text) return
      if (text.trimStart().startsWith("[H17 evidence gate]")) return // our own re-prompt is not a user turn (Codex r4 P1-c)
      reprompts.delete(input.sessionID ?? "unset") // new user request: fresh re-prompt budget (Codex r2 P2-m)
      await cc("prompt", { sessionID: input.sessionID ?? "unset", prompt: text })
    },
    "tool.execute.before": async (
      item: { tool: string; sessionID?: string; callID?: unknown },
      out: { args: Record<string, unknown> },
    ) => {
      lastPart.delete(item.sessionID ?? "unset") // a tool call follows: the previous text part was intermediate
      const v = await cc("pre", { sessionID: item.sessionID ?? "unset", tool_name: item.tool, tool_input: out.args ?? {} })
      if (v.decision === "block") throw new Error(`[H17] ${v.reason ?? v.rule}`)
    },
    "tool.execute.after": async (
      item: { tool: string; sessionID?: string; args?: Record<string, unknown> },
      out: { title: string; output: string; metadata: Record<string, unknown> },
    ) => {
      const rc = typeof out.metadata?.exit === "number" ? (out.metadata.exit as number) : undefined
      await cc("post", {
        sessionID: item.sessionID ?? "unset",
        tool_name: item.tool,
        tool_input: item.args ?? {},
        tool_response: { exit_code: rc, stdout: clipOut(String(out.output ?? "")) },
      })
    },
    // Headless `opencode run` exits on session.idle before an async re-prompt can land,
    // so the evidence gate also runs when the assistant text part completes: a blocked
    // claim gets the gate verdict appended to the visible text and an H6 block row.
    "experimental.text.complete": async (
      input: { sessionID: string; messageID: string; partID: string },
      output: { text: string },
    ) => {
      const text = String(output.text ?? "")
      if (!text.trim()) return
      // The text parts of one message are one answer (Codex r3 P2: Evidence in part 1, Status in part 2): judge the
      // accumulated message text, not the part alone.
      const prev = lastPart.get(input.sessionID)
      const whole = prev && prev.messageID === input.messageID ? `${prev.text}\n${text}` : text
      lastPart.set(input.sessionID, { messageID: input.messageID, text: whole })
      // ADR-009: a text part is not necessarily the final answer, so the Status line is demanded only at
      // session.idle / process exit; here a declared `Status: complete` / a trailer / the vocabulary backstop still bind.
      const v = await cc("stop", { sessionID: input.sessionID, last_assistant_message: whole }, ["--max-blocks", "99", "--no-count", "--no-status-required"])
      // ccs#421: `Status: complete` in part 1 and the `Evidence:` trailer in a later part — a block whose ONLY problem is
      // the missing trailer may still be answered by the next part of this message, so it is not annotated here; the
      // final text is judged at session.idle / process exit (Status required), which reports it if it stays missing
      const problems = ((v as { problems?: string[] }).problems ?? []).map(String)
      // only a DECLARED `Status: complete` waits for its trailer; a vocabulary claim in a session without tool rows
      // ("実装完了しました。") is still annotated at once (the 2026-10-14 regression anchor)
      const declared = /^\s*Status:\s*complete\s*$/m.test(whole)
      const trailerOnly =
        declared && problems.length > 0 && problems.every((x) => x.startsWith("completion claim without `Evidence"))
      if (v.decision === "block" && !trailerOnly) output.text = `${text}\n\n[H17 evidence gate] ${v.reason ?? ""}`
      else if ((v as { note?: string }).note) output.text = `${text}\n\n${(v as { note?: string }).note}` // Status: partial is visible (Codex r2 P2)
    },
    event: async ({ event }: { event: { type?: string; properties?: Record<string, unknown> } }) => {
      if (event.type !== "session.idle") return
      const sessionID = String(event.properties?.sessionID ?? "")
      if (!sessionID) return
      const n = reprompts.get(sessionID) ?? 0
      let last = ""
      try {
        const res = await client.session.messages({ path: { id: sessionID } })
        const msgs = (res?.data ?? res ?? []) as Array<{ info?: { role?: string }; parts?: unknown }>
        for (const m of msgs) if (m?.info?.role === "assistant") last = textOf(m.parts) || last
      } catch {
        return
      }
      if (!last) return
      if (n >= MAX_REPROMPTS) {
        // aidd-governance#186 P3 (OpenCode silent exhaustion): the re-prompt budget is spent, but the
        // final text is still evaluated through the python release path (--max-blocks 0), which writes
        // an `evidence.max-blocks.would-block` H6 row when it would have blocked.  The user-visible annotation
        // for headless runs is the one experimental.text.complete already appended to the text; this idle-time
        // pass only makes the release auditable in the ledger (review 2026-10-16: ledger-only, not a UI note).
        const r = await cc("stop", { sessionID, last_assistant_message: last }, ["--max-blocks", "0", "--no-count"])
        const line = (r as { note?: string }).note
        if (line) process.stderr.write(`${line} — ${r.reason ?? ""}\n`) // the release is never silent (Codex r4 P2)
        lastPart.delete(sessionID) // judged; the exit fallback is released only now (Codex r3 P1: not before the await)
        return
      }
      const v = await cc("stop", { sessionID, last_assistant_message: last })
      lastPart.delete(sessionID) // judged; a headless exit during the awaits above still had the fallback
      if (v.decision !== "block") return
      reprompts.set(sessionID, n + 1)
      try {
        await client.session.prompt({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text: `[H17 evidence gate] ${v.reason ?? ""} — fix the report before claiming completion.` }] },
        })
      } catch {
        /* re-prompt failure is visible in the H6 ledger row written by aidd_cc.py */
      }
    },
  }
}

export default AiddCommonControl
