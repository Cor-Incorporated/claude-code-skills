// OpenCode plugin entry for the H17 common control (AIDD).
// Deployed to ~/.config/opencode/plugins/aidd-cc.ts and listed in opencode.jsonc "plugin".
//
//   chat.message          -> prompt            (register user decisions / deadlines)
//   tool.execute.before   -> pre               (C-ITER; throws to block the call)
//   tool.execute.after    -> post              (record rc/output for evidence binding)
//   permission.ask        -> permission        (allow only when a user decision binds it)
//   event session.idle    -> stop              (C-EVIDENCE; re-prompts the session once)
//
// The verdict logic is python (hooks/lib/aidd_cc.py) shared with Claude/Codex/Cursor,
// so one oracle covers all four real entries.  Session key: sessionID.
import os from "os"
import path from "path"

const CC_PY = process.env.AIDD_CC_PY ?? path.join(os.homedir(), ".claude", "hooks", "lib", "aidd_cc.py")
const AGENT = "opencode"
const MAX_REPROMPTS = 2

type Verdict = { decision?: string; reason?: string; rule?: string; problems?: string[] }

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
    return line ? (JSON.parse(line) as Verdict) : { decision: "allow", rule: "empty" }
  } catch (e) {
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
  return {
    "chat.message": async (
      input: { sessionID?: string },
      output: { message?: unknown; parts?: unknown },
    ) => {
      const text = textOf(output.parts)
      if (!text) return
      await cc("prompt", { sessionID: input.sessionID ?? "unset", prompt: text })
    },
    "tool.execute.before": async (
      item: { tool: string; sessionID?: string; callID?: unknown },
      out: { args: Record<string, unknown> },
    ) => {
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
        tool_response: { exit_code: rc, stdout: String(out.output ?? "").slice(0, 4000) },
      })
    },
    "permission.ask": async (
      input: { sessionID?: string; type?: string; title?: string; metadata?: Record<string, unknown>; pattern?: unknown },
      output: { status: "ask" | "deny" | "allow" },
    ) => {
      if (output.status !== "ask") return
      const v = await cc("permission", {
        sessionID: input.sessionID ?? "unset",
        tool_input: { command: String(input.title ?? ""), pattern: input.pattern ?? null, ...(input.metadata ?? {}) },
        message: String(input.type ?? ""),
      })
      if (v.decision === "allow") output.status = "allow"
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
      const v = await cc("stop", { sessionID: input.sessionID, last_assistant_message: text }, ["--max-blocks", "99", "--no-count"])
      if (v.decision === "block") output.text = `${text}\n\n[H17 evidence gate] ${v.reason ?? ""}`
    },
    event: async ({ event }: { event: { type?: string; properties?: Record<string, unknown> } }) => {
      if (event.type !== "session.idle") return
      const sessionID = String(event.properties?.sessionID ?? "")
      if (!sessionID) return
      const n = reprompts.get(sessionID) ?? 0
      if (n >= MAX_REPROMPTS) return
      let last = ""
      try {
        const res = await client.session.messages({ path: { id: sessionID } })
        const msgs = (res?.data ?? res ?? []) as Array<{ info?: { role?: string }; parts?: unknown }>
        for (const m of msgs) if (m?.info?.role === "assistant") last = textOf(m.parts) || last
      } catch {
        return
      }
      if (!last) return
      const v = await cc("stop", { sessionID, last_assistant_message: last })
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
