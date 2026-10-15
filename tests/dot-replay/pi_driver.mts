// Replay driver for the Pi entry (aidd-governance#186 P2-6, Pi arm): one hook payload (Claude-Code-shaped
// JSON on stdin) is translated into the real extension's handlers with a fake ExtensionAPI, exactly as
// test-pi-extension.sh does.  Extension under test: $AIDD_PI_EXT (repo pi/aidd-cc.ts or the deployed
// ~/.pi/agent/extensions/aidd-cc.ts); oracle: $AIDD_CC_PY.  Needs node >= 22 (--experimental-strip-types).
import { readFileSync } from "node:fs";
const ext = (await import(process.env.AIDD_PI_EXT ?? "")).default;
const handlers = new Map<string, any>();
const pi = { on: (ev: string, h: any) => { handlers.set(ev, h); return () => {}; } };
ext(pi);
const call = (ev: string, e: any, ctx: any = {}) => handlers.get(ev)?.(e, ctx);
const p = JSON.parse(readFileSync(0, "utf-8") || "{}");
const sid = String(p.session_id ?? "unset");
await call("session_start", {}, { sessionManager: { getSessionId: () => sid } });
const ev = String(p.hook_event_name ?? "");
const toolName = (t: string) => (t === "Bash" ? "bash" : t === "Edit" ? "edit" : t === "Write" ? "write" : String(t ?? "tool"));
let out: Record<string, unknown> = { decision: "allow", event: ev };
if (ev === "PreToolUse") {
  const r = await call("tool_call", { toolName: toolName(p.tool_name), input: p.tool_input ?? {} });
  if (r?.block) out = { decision: "block", reason: r.reason, event: ev };
} else if (ev === "PostToolUse" || ev === "PostToolUseFailure") {
  const r = p.tool_response ?? {};
  const rc = typeof r === "object" && r !== null ? r.exit_code : undefined;
  const text = typeof r === "object" && r !== null ? String(r.stdout ?? r.output ?? "") : String(r ?? "");
  await call("tool_result", { toolName: toolName(p.tool_name), input: p.tool_input ?? {}, structuredContent: rc === undefined ? undefined : { exit_code: rc }, isError: ev === "PostToolUseFailure", content: [{ type: "text", text }] });
} else if (ev === "UserPromptSubmit") {
  await call("before_agent_start", { messageType: "user", prompt: String(p.prompt ?? "") });
} else if (ev === "Stop") {
  const r = await call("turn_end", { message: { content: [{ type: "text", text: String(p.last_assistant_message ?? "") }] }, toolResults: [] });
  if (r?.continue) out = { decision: "block", reason: r.entries?.[0]?.content ?? "", event: ev };
  else if (r?.entries?.length) out = { decision: "allow", note: r.entries[0].content, event: ev };
} else {
  out = { decision: "allow", event: ev, note: "unmapped event" };
}
console.log(JSON.stringify(out, null, 1));
