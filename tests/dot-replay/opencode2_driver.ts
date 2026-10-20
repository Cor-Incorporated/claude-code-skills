// Replay driver for the OpenCode 2.x entry (opencode/aidd-cc-v2/index.ts, the plugin the local `opencode` = opencode2
// runs since the 2026-10-19 re-platform). One Claude-Code-shaped hook payload (JSON on stdin) is translated into the
// real 2.x plugin's registrations on a fake `@opencode/plugin` ctx, with 2.x tool vocabulary (`shell`, `edit`,
// `write`, `read`; `path`, `oldString`, `newString`), and the harness-visible outcome is printed as
// {"decision": "allow"|"block", ...}. The plugin under test is $AIDD_OC2_PLUGIN (repo or the deployed
// ~/.config/opencode/plugins/aidd-cc-v2/index.ts); the oracle it spawns is $AIDD_CC_PY.
//
// Stop: the plugin judges the final answer on `session.execution.succeeded` (after `session.text.ended`). A block is
// visible as a re-prompt through ctx.session.prompt carrying "[H17 evidence gate]" — that is the decision here.
const pluginPath = process.env.AIDD_OC2_PLUGIN ?? ""
const mod = await import(pluginPath)
const plugin = mod.default

const hooks: Record<string, (e: any) => Promise<void>> = {}
const prompts: { text: string }[] = []
const notes: { text: string }[] = []
const queue: unknown[] = []
let wake: (() => void) | undefined
let drained: (() => void) | undefined
const drainedP = new Promise<void>((r) => (drained = r))
let pushedAll = false

async function* events() {
  for (;;) {
    if (queue.length) {
      yield queue.shift()
      continue
    }
    // the loop asks for the next event only after it finished the previous one (including the awaited stop judgment)
    if (pushedAll) drained?.()
    await new Promise<void>((r) => (wake = r))
    wake = undefined
  }
}

await plugin.setup({
  location: { directory: process.cwd(), project: { directory: process.cwd() } },
  session: {
    hook: async (name: string, fn: (e: any) => Promise<void>) => {
      hooks["session." + name] = fn
    },
    prompt: async (input: { text: string }) => void prompts.push(input),
    synthetic: async (input: { text: string }) => void notes.push(input),
  },
  tool: {
    hook: async (name: string, fn: (e: any) => Promise<void>) => {
      hooks["tool." + name] = fn
    },
  },
  event: { subscribe: () => events() },
})

const TOOL: Record<string, string> = { bash: "shell", edit: "edit", write: "write", read: "read", multiedit: "edit" }
function toV2(toolName: string, input: Record<string, unknown>) {
  const tool = TOOL[toolName.toLowerCase()] ?? toolName.toLowerCase()
  const i: Record<string, unknown> = { ...input }
  if (i.file_path !== undefined && i.path === undefined) {
    i.path = i.file_path
    delete i.file_path
  }
  if (i.old_string !== undefined) {
    i.oldString = i.old_string
    delete i.old_string
  }
  if (i.new_string !== undefined) {
    i.newString = i.new_string
    delete i.new_string
  }
  return { tool, input: i }
}

const raw = await new Response(Bun.stdin.stream()).text()
const p = raw.trim() ? JSON.parse(raw) : {}
const sessionID = String(p.session_id ?? p.sessionID ?? "unset")
const ev = String(p.hook_event_name ?? "")
let out: Record<string, unknown> = { decision: "allow", event: ev }
const call = toV2(String(p.tool_name ?? "Bash"), (p.tool_input ?? {}) as Record<string, unknown>)

if (ev === "PreToolUse") {
  try {
    await hooks["tool.execute.before"]({ tool: call.tool, sessionID, agent: "build", messageID: "m", id: "c", input: call.input })
  } catch (e) {
    out = { decision: "block", reason: String((e as Error).message ?? e), event: ev }
  }
} else if (ev === "PostToolUse" || ev === "PostToolUseFailure") {
  const r = p.tool_response ?? {}
  const rc = typeof r === "object" && r !== null ? r.exit_code : undefined
  const text = typeof r === "object" && r !== null ? String(r.stdout ?? r.output ?? "") : String(r ?? "")
  const failed = ev === "PostToolUseFailure"
  await hooks["tool.execute.after"]({
    tool: call.tool,
    sessionID,
    agent: "build",
    messageID: "m",
    id: "c",
    input: call.input,
    ...(failed
      ? { status: "error", error: { message: text || "tool failed" } }
      : { status: "completed", result: { content: text, metadata: rc === undefined ? {} : { exit: rc } } }),
  })
} else if (ev === "UserPromptSubmit") {
  await hooks["session.prompt"]({ sessionID, messageID: "u", prompt: { text: String(p.prompt ?? ""), files: [] }, delivery: "steer" })
} else if (ev === "Stop") {
  queue.push({ type: "session.text.ended", data: { sessionID, assistantMessageID: "a", ordinal: 0, text: String(p.last_assistant_message ?? "") } })
  queue.push({ type: "session.execution.succeeded", data: { sessionID } })
  pushedAll = true
  wake?.()
  await Promise.race([drainedP, new Promise((r) => setTimeout(r, 60_000))])
  const gate = prompts.find((x) => x.text.includes("[H17 evidence gate]"))
  if (gate) out = { decision: "block", reason: gate.text.split("[H17 evidence gate]").pop()?.trim(), event: ev }
  else if (notes.length) out = { decision: "allow", event: ev, note: notes.map((n) => n.text).join(" / ") }
} else {
  out = { decision: "allow", event: ev, note: "unmapped event" }
}
console.log(JSON.stringify(out, null, 1))
process.exit(0)
