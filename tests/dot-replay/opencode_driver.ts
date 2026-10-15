// Replay driver for the OpenCode entry (aidd-governance#186 P2-6): one hook payload (Claude-Code-shaped
// JSON on stdin) is translated into the real plugin's hook calls, exactly as test-opencode-plugin.sh does,
// and the harness-visible outcome is printed as {"decision": "allow"|"block", ...}.  The plugin under test
// is $AIDD_OC_PLUGIN (repo opencode/aidd-cc.ts or the deployed ~/.config/opencode/plugins/aidd-cc.ts) and
// the oracle it spawns is $AIDD_CC_PY — so a `--deployed` replay exercises the registered plugin bytes.
const pluginPath = process.env.AIDD_OC_PLUGIN ?? ""
const mod = await import(pluginPath)
const plugin = mod.default ?? mod.AiddCommonControl
const hooks: any = await plugin({ client: {} })
const raw = await new Response(Bun.stdin.stream()).text()
const p = raw.trim() ? JSON.parse(raw) : {}
const sessionID = String(p.session_id ?? p.sessionID ?? "unset")
const ev = String(p.hook_event_name ?? "")
let out: Record<string, unknown> = { decision: "allow", event: ev }
if (ev === "PreToolUse") {
  try {
    await hooks["tool.execute.before"]({ tool: p.tool_name ?? "bash", sessionID }, { args: p.tool_input ?? {} })
  } catch (e) {
    out = { decision: "block", reason: String((e as Error).message ?? e), event: ev }
  }
} else if (ev === "PostToolUse" || ev === "PostToolUseFailure") {
  const r = p.tool_response ?? {}
  const rc = typeof r === "object" && r !== null ? r.exit_code : undefined
  const text = typeof r === "object" && r !== null ? String(r.stdout ?? r.output ?? "") : String(r ?? "")
  await hooks["tool.execute.after"]({ tool: p.tool_name ?? "bash", sessionID, args: p.tool_input ?? {} }, { title: "", output: text, metadata: { exit: rc } })
} else if (ev === "UserPromptSubmit") {
  await hooks["chat.message"]({ sessionID }, { parts: [{ type: "text", text: String(p.prompt ?? "") }] })
} else if (ev === "Stop") {
  const o = { text: String(p.last_assistant_message ?? "") }
  await hooks["experimental.text.complete"]({ sessionID, messageID: "m", partID: "p" }, o)
  if (o.text.includes("[H17 evidence gate]")) out = { decision: "block", reason: o.text.split("[H17 evidence gate]").pop()?.trim(), event: ev }
} else {
  out = { decision: "allow", event: ev, note: "unmapped event" }
}
console.log(JSON.stringify(out, null, 1))
