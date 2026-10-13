// Pi (@earendil-works/pi-coding-agent) extension for the H17 common control.
// Install: copy to ~/.pi/agent/extensions/aidd-cc.ts  (or `pi -e pi/aidd-cc.ts`).
//
//   before_agent_start (user prompt) -> prompt            (decisions / deadline)
//   tool_call                        -> pre               ({ block: true, reason } on C-ITER)
//   tool_result                      -> post              (rc/output for evidence binding)
//   turn_end                         -> stop              (C-EVIDENCE; one forced continuation)
//
// Same python oracle as Claude Code / Codex / Cursor / OpenCode: ~/.claude/hooks/lib/aidd_cc.py.
// Pi has no PermissionRequest / AskUserQuestion hook: C-DECISION re-ask suppression is
// BLOCKED_PLATFORM here (documented in tests/dot-replay/cases.py).
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

type Verdict = { decision?: string; reason?: string; rule?: string };

const CC_PY = process.env.AIDD_CC_PY ?? join(homedir(), ".claude", "hooks", "lib", "aidd_cc.py");
const AGENT = "pi";
const MAX_CONTINUATIONS = 2;

export function runCC(cmd: string, payload: Record<string, unknown>): Promise<Verdict> {
  if (process.env.AIDD_CC_DISABLE === "1") return Promise.resolve({ decision: "allow", rule: "disabled" });
  return new Promise((resolve) => {
    const child = spawn("python3", ["-I", CC_PY, cmd, "--agent", AGENT], {
      env: { ...process.env, AIDD_CC_AGENT: AGENT },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += String(d)));
    child.on("error", () => resolve({ decision: "allow", rule: "spawn-error" }));
    child.on("close", () => {
      const line = out.trim().split("\n").pop() ?? "";
      try {
        resolve(line ? (JSON.parse(line) as Verdict) : { decision: "allow", rule: "empty" });
      } catch {
        resolve({ decision: "allow", rule: "parse-error" });
      }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

function textOf(message: unknown): string {
  const content = (message as { content?: unknown })?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((p) => (p && typeof p === "object" && (p as { type?: string }).type === "text" ? String((p as { text?: string }).text ?? "") : ""))
    .join("\n");
}

export default function aiddCommonControl(pi: any) {
  let sessionID = `pi-${process.pid}`;
  let continuations = 0;

  pi.on("session_start", async (_event: unknown, ctx: any) => {
    const id = ctx?.sessionManager?.getSessionId?.() ?? ctx?.sessionManager?.getSessionFile?.();
    if (id) sessionID = String(id).split("/").pop()!.replace(/\.jsonl$/, "");
    continuations = 0;
  });

  pi.on("before_agent_start", async (event: any) => {
    if (event?.messageType !== "user" || !event.prompt) return;
    await runCC("prompt", { session_id: sessionID, prompt: String(event.prompt) });
  });

  pi.on("tool_call", async (event: any) => {
    const input = event?.input ?? {};
    const tool = event?.toolName === "bash" ? "Bash" : event?.toolName === "edit" ? "Edit" : event?.toolName === "write" ? "Write" : String(event?.toolName ?? "tool");
    const v = await runCC("pre", { session_id: sessionID, tool_name: tool, tool_input: { command: input.command, file_path: input.path ?? input.file_path } });
    if (v.decision === "block") return { block: true, reason: `[H17] ${v.reason ?? v.rule}` };
    return undefined;
  });

  pi.on("tool_result", async (event: any) => {
    const input = event?.input ?? {};
    const tool = event?.toolName === "bash" ? "Bash" : String(event?.toolName ?? "tool");
    const rc = typeof event?.details?.exitCode === "number" ? event.details.exitCode : event?.isError ? 1 : 0;
    await runCC("post", {
      session_id: sessionID,
      tool_name: tool,
      tool_input: { command: input.command, file_path: input.path ?? input.file_path },
      tool_response: { exit_code: rc, stdout: textOf(event).slice(0, 4000) },
    });
    return undefined;
  });

  pi.on("turn_end", async (event: any) => {
    const last = textOf(event?.message);
    if (!last || (event?.toolResults?.length ?? 0) > 0) return undefined; // not a final answer yet
    const v = await runCC("stop", { session_id: sessionID, last_assistant_message: last });
    if (v.decision !== "block" || continuations >= MAX_CONTINUATIONS) return undefined;
    continuations += 1;
    return {
      continue: true,
      entries: [
        {
          type: "custom_message",
          customType: "aidd-cc",
          display: true,
          content: `[H17 evidence gate] ${v.reason ?? ""} — fix the report before claiming completion.`,
        },
      ],
    };
  });
}
