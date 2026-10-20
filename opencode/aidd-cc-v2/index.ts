// OpenCode 2.x plugin entry for the H17 common control (AIDD) — the port of ../aidd-cc.ts (1.x hook API) to the
// `@opencode/plugin` 2.x promise API (upstream anomalyco/opencode `dev`, CLI 2.0.32, 2026-10-18 spike).
//
// Deployed as a DIRECTORY (2.x resolves `<dir>/index.ts`): ~/.config/opencode/plugins/aidd-cc-v2/ and listed in
// opencode.json(c) as `"plugins": ["/abs/path/.config/opencode/plugins/aidd-cc-v2"]`. A bare file path is admitted
// only as a legacy source with a warning. No imports from @opencode/*: a local plugin resolves imports relative to
// its own directory (Bun.resolveSync), so this file uses node builtins only and exports a plain `{ id, setup }`.
//
// 1.x hook                      -> 2.x equivalent
//   chat.message                -> ctx.session.hook("prompt")              (C-DECISION: decisions / deadlines)
//   tool.execute.before         -> ctx.tool.hook("execute.before")          (C-ITER; a thrown Error denies the call —
//                                                                             the promise adapter wraps it as Tool.Error)
//   tool.execute.after          -> ctx.tool.hook("execute.after")           (rc / output rows for evidence binding)
//   experimental.text.complete  -> events session.text.ended (per assistant message, ordinal order)
//   session.idle                -> event session.execution.succeeded          (C-EVIDENCE on the final answer:
//                                                                             block -> ctx.session.prompt re-prompt,
//                                                                             max 2; partial/unverified -> synthetic note)
// A text part followed by a tool call (session.tool.called) is intermediate and is dropped, as in 1.x.
// The verdict logic is python (hooks/lib/aidd_cc.py) shared with every other entry. Session key: sessionID.
import os from "node:os"
import path from "node:path"
import { appendFileSync, mkdirSync } from "node:fs"
import { spawn } from "node:child_process"

const CC_PY = process.env.AIDD_CC_PY ?? path.join(os.homedir(), ".claude", "hooks", "lib", "aidd_cc.py")
const AGENT = "opencode"
// Head + tail, never the head alone: the status line (`X; echo exit=$?`) and test summaries are the LAST lines, and
// a head-only cut let a failing X's early `exit=0` stand in for the echo's `exit=1` (ADR-011, Codex review P2).
const clipOut = (s: string, n = 4000): string => (s.length <= n ? s : `${s.slice(0, n / 2)}\n…\n${s.slice(-n / 2)}`)
const MAX_REPROMPTS = 2

type Verdict = { decision?: string; reason?: string; rule?: string; problems?: string[]; note?: string; would_block?: boolean; status?: string }

// aidd-governance#186 P2-2: a spawn / parse failure of the oracle is a visible degradation (H6 error row), never a
// silent allow. Same row shape as aidd-cc-adapter.sh ledger_error().
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

function cc(cmd: string, payload: Record<string, unknown>, extra: string[] = []): Promise<Verdict> {
  if (process.env.AIDD_CC_DISABLE === "1") return Promise.resolve({ decision: "allow", rule: "disabled" })
  return new Promise((resolve) => {
    try {
      // detached = its own process group (owner live run 2026-10-19: `opencode2 run` → `[H17 unavailable]
      // python-exit-null:stop`). `run` returns on the same session.execution.succeeded event the stop judgment starts on,
      // and the CLI then stops its private server with SIGTERM to the group; the oracle died mid-judgment before writing
      // its ledger row. In its own group it finishes and writes the row, which the launcher prints after the CLI returns.
      const proc = spawn("python3", ["-I", CC_PY, cmd, "--agent", AGENT, ...extra], {
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, AIDD_CC_AGENT: AGENT },
        detached: true,
      })
      let out = ""
      proc.stdout.on("data", (d) => (out += String(d)))
      proc.stderr.on("data", () => {})
      proc.on("error", (e) => {
        ledgerError(`spawn-or-parse-error:${cmd}`, String(e))
        resolve({ decision: "allow", rule: "error", reason: String(e) })
      })
      proc.on("close", (code) => {
        const line = out.trim().split("\n").pop() ?? ""
        if (!line) {
          ledgerError(`python-exit-${code}:${cmd}`, "")
          return resolve({ decision: "allow", rule: "empty" })
        }
        try {
          resolve(JSON.parse(line) as Verdict)
        } catch (e) {
          ledgerError(`spawn-or-parse-error:${cmd}`, String(e))
          resolve({ decision: "allow", rule: "error", reason: String(e) })
        }
      })
      // Codex #426 P2: on Node 22 a child that exits before reading a large payload raises an async EPIPE on stdin,
      // which neither proc.on("error") nor the outer try/catch sees. The close handler already settles the verdict.
      proc.stdin.on("error", (e) => ledgerError(`stdin-error:${cmd}`, String(e)))
      proc.stdin.end(JSON.stringify(payload))
    } catch (e) {
      ledgerError(`spawn-or-parse-error:${cmd}`, String(e))
      resolve({ decision: "allow", rule: "error", reason: String(e) })
    }
  })
}

/** Text of a 2.x tool result: `content` is a string or an array of {type:"text"|"file"} parts; `output` may be a value. */
function resultText(result: unknown): string {
  if (!result || typeof result !== "object") return ""
  const r = result as { content?: unknown; output?: unknown }
  if (typeof r.content === "string") return r.content
  if (Array.isArray(r.content))
    return r.content
      .map((c) => (c && typeof c === "object" && (c as { type?: string }).type === "text" ? String((c as { text?: string }).text ?? "") : ""))
      .join("\n")
  if (typeof r.output === "string") return r.output
  if (r.output !== undefined) {
    try {
      return JSON.stringify(r.output)
    } catch {
      return ""
    }
  }
  return ""
}

/** Exit code of a shell-like tool result: metadata keys seen across tools, else the `[exit code: N]` trailer. */
function exitCodeOf(result: unknown, text: string): number | undefined {
  const m = (result && typeof result === "object" ? (result as { metadata?: Record<string, unknown> }).metadata : undefined) ?? {}
  for (const k of ["exit", "exitCode", "exit_code", "code", "status"]) {
    const v = m[k]
    if (typeof v === "number") return v
  }
  const t = /\[exit code: (-?\d{1,3})\]\s*$/.exec(text.trim())
  return t ? Number(t[1]) : undefined
}

/**
 * Codex #426 P1-b: 2.x GPT-family models edit through the native `patch` tool (`{ patchText }` in the
 * `*** Begin Patch / *** Update File: <path> / *** Add File: / *** Delete File: / *** Move to:` grammar of
 * packages/util/src/patch.ts). The shared oracle recognizes edits by tool name + file_path (family `edit:<path>`,
 * iteration key = digest of the edit body), so a patch is presented as an Edit of its first file with the whole
 * patch text as the body; every touched path travels in `edits` for the ledger.
 */
function normalizeCall(tool: string, input: unknown): { tool: string; input: Record<string, unknown> } {
  const raw = (input && typeof input === "object" ? input : {}) as Record<string, unknown>
  if (tool !== "patch" || typeof raw.patchText !== "string") return { tool, input: raw }
  const edits = [...raw.patchText.matchAll(/^\*\*\* (Update|Add|Delete) File: (.+)$/gm)].map((m) => ({ op: m[1].toLowerCase(), path: m[2].trim() }))
  const moves = [...raw.patchText.matchAll(/^\*\*\* Move to: (.+)$/gm)].map((m) => m[1].trim())
  return {
    tool: edits[0]?.op === "add" ? "Write" : "Edit",
    input: {
      ...raw,
      file_path: edits[0]?.path ?? "?",
      edits: [...edits, ...moves.map((path) => ({ op: "move", path }))],
      new_string: raw.patchText,
      content: raw.patchText,
    },
  }
}

function eventData(ev: unknown): Record<string, any> {
  const e = ev as { data?: Record<string, any>; properties?: Record<string, any> }
  return e?.data ?? e?.properties ?? (ev as Record<string, any>) ?? {}
}

export default {
  id: "aidd-cc",
  setup: async (ctx: any) => {
    // review #426 M1: patch paths are relative; the oracle resolves them against the payload cwd, not the server's
    const cwd = String(ctx?.location?.directory ?? process.cwd())
    const reprompts = new Map<string, number>()
    // per session: the assistant message currently being written and its text parts in ordinal order
    const texts = new Map<string, { messageID: string; parts: Map<number, string> }>()
    const textOf = (sid: string) => {
      const cur = texts.get(sid)
      if (!cur) return ""
      return [...cur.parts.entries()].sort((a, b) => a[0] - b[0]).map(([, t]) => t).join("\n")
    }

    await ctx.session.hook("prompt", async (e: any) => {
      const sid = String(e?.sessionID ?? "unset")
      const text = String(e?.prompt?.text ?? "")
      if (!text.trim()) return
      if (text.trimStart().startsWith("[H17 evidence gate]")) return // our own re-prompt is not a user turn (Codex r4 P1-c)
      reprompts.delete(sid) // a new user request gets a fresh re-prompt budget (Codex r2 P2-m)
      texts.delete(sid)
      await cc("prompt", { sessionID: sid, prompt: text })
    })

    await ctx.tool.hook("execute.before", async (e: any) => {
      const sid = String(e?.sessionID ?? "unset")
      texts.delete(sid) // a tool call follows: whatever text came before was intermediate
      const call = normalizeCall(String(e?.tool ?? ""), e?.input)
      const v = await cc("pre", { sessionID: sid, cwd, tool_name: call.tool, tool_input: call.input })
      if (v.decision === "block") throw new Error(`[H17] ${v.reason ?? v.rule}`) // -> Tool.Error, the call is denied
    })

    await ctx.tool.hook("execute.after", async (e: any) => {
      const sid = String(e?.sessionID ?? "unset")
      const text = e?.status === "completed" ? resultText(e?.result) : String(e?.error?.message ?? "")
      const call = normalizeCall(String(e?.tool ?? ""), e?.input)
      // review #426 L1: a failed call carries a non-zero rc so a rejected patch is not recorded as a successful write
      const rc = e?.status === "completed" ? exitCodeOf(e?.result, text) : 1
      // review #426 M1: a patch touching several files records one post row per file, so every touched path is a
      // written path for Readback binding (the oracle reads the path from the edit key); paths resolve against cwd
      const files = Array.isArray(call.input.edits) ? (call.input.edits as { path?: string }[]).map((x) => String(x.path ?? "")).filter(Boolean) : []
      const targets = files.length > 1 ? [...new Set(files)] : [String(call.input.file_path ?? "")]
      for (const file of targets) {
        await cc("post", {
          sessionID: sid,
          cwd,
          tool_name: call.tool,
          tool_input: files.length > 1 ? { ...call.input, file_path: file } : call.input,
          // metadata.truncated: the 2.x shell cut its capture, so the echo's line may be gone (ADR-011, Codex review r2)
          tool_response: { exit_code: rc, output: clipOut(text), truncated: e?.result?.metadata?.truncated === true },
        })
      }
    })

    const judge = async (sid: string) => {
      const last = textOf(sid)
      texts.delete(sid)
      if (!last.trim()) return
      const n = reprompts.get(sid) ?? 0
      if (n >= MAX_REPROMPTS) {
        // the re-prompt budget is spent: the python release path still evaluates and writes a would-block row
        // (aidd-governance#186 P3); the note goes to the session as a synthetic message so it is never silent
        const r = await cc("stop", { sessionID: sid, last_assistant_message: last }, ["--max-blocks", "0", "--no-count"])
        const line = r.note ? `${r.note} — ${r.reason ?? ""}` : ""
        if (line) await note(sid, line)
        return
      }
      const v = await cc("stop", { sessionID: sid, last_assistant_message: last })
      if (v.decision === "block") {
        reprompts.set(sid, n + 1)
        try {
          await ctx.session.prompt({ sessionID: sid, text: `[H17 evidence gate] ${v.reason ?? ""} — fix the report before claiming completion.` })
        } catch {
          /* re-prompt failure is visible in the H6 block row written by aidd_cc.py */
        }
        return
      }
      if (v.note) await note(sid, v.note) // ADR-009: Status: partial / unverified passes with its note shown
    }

    const note = async (sid: string, text: string) => {
      try {
        if (typeof ctx.session?.synthetic === "function") {
          // Codex #426 P1-a: 2.x `session.synthetic` resumes the session by default, which would re-run the model
          // on the note (and note the new answer again, forever). A display-only note must not resume.
          await ctx.session.synthetic({ sessionID: sid, text, description: "H17 evidence gate", resume: false })
          return
        }
      } catch {
        /* fall through to stderr */
      }
      process.stderr.write(`${text}\n`)
    }

    // Event loop: text parts, tool calls, and the end of each execution (the final answer boundary).
    ;(async () => {
      try {
        for await (const ev of ctx.event.subscribe()) {
          const type = String((ev as { type?: string })?.type ?? "")
          const d = eventData(ev)
          const sid = String(d.sessionID ?? "unset")
          if (type === "session.text.ended") {
            const mid = String(d.assistantMessageID ?? "")
            const cur = texts.get(sid)
            const entry = cur && cur.messageID === mid ? cur : { messageID: mid, parts: new Map<number, string>() }
            entry.parts.set(Number(d.ordinal ?? entry.parts.size), String(d.text ?? ""))
            texts.set(sid, entry)
          } else if (type === "session.tool.called") {
            texts.delete(sid)
          } else if (type === "session.execution.succeeded") {
            await judge(sid)
          }
        }
      } catch (e) {
        ledgerError("event-stream-error", String(e))
      }
    })()
  },
}
