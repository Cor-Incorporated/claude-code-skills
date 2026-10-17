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
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

type Verdict = { decision?: string; reason?: string; rule?: string; would_block?: boolean; note?: string };

const CC_PY = process.env.AIDD_CC_PY ?? join(homedir(), ".claude", "hooks", "lib", "aidd_cc.py");
const AGENT = "pi";
const MAX_CONTINUATIONS = 2;

// aidd-governance#186 P2-2: a spawn / parse failure of the oracle leaves an H6 error row (same shape as
// aidd-cc-adapter.sh ledger_error()) instead of passing silently.
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

export function runCC(cmd: string, payload: Record<string, unknown>): Promise<Verdict> {
  if (process.env.AIDD_CC_DISABLE === "1") return Promise.resolve({ decision: "allow", rule: "disabled" });
  return new Promise((resolve) => {
    const child = spawn("python3", ["-I", CC_PY, cmd, "--agent", AGENT], {
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

function editInput(input: any): Record<string, unknown> {
  // Pi edit/write carry oldText/newText/content: keep them so distinct edits get
  // distinct keys in the common control (Codex r3 P2-4).
  return {
    command: input?.command,
    file_path: input?.path ?? input?.file_path,
    old_string: input?.oldText ?? input?.old_string,
    new_string: input?.newText ?? input?.new_string,
    content: input?.content,
  };
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
    if (String(event.prompt).trimStart().startsWith("[H17 evidence gate]")) return;
    continuations = 0; // a new user request gets its own gate budget (Codex r2 P2-m)
    await runCC("prompt", { session_id: sessionID, prompt: String(event.prompt) });
  });

  pi.on("tool_call", async (event: any) => {
    const input = event?.input ?? {};
    const tool = event?.toolName === "bash" ? "Bash" : event?.toolName === "edit" ? "Edit" : event?.toolName === "write" ? "Write" : String(event?.toolName ?? "tool");
    const v = await runCC("pre", { session_id: sessionID, tool_name: tool, tool_input: editInput(input) });
    if (v.decision === "block") return { block: true, reason: `[H17] ${v.reason ?? v.rule}` };
    return undefined;
  });

  pi.on("tool_result", async (event: any) => {
    const input = event?.input ?? {};
    const tool = event?.toolName === "bash" ? "Bash" : String(event?.toolName ?? "tool");
    // Pi 1.2.0 bash results carry the exit code in structuredContent.exit_code (Codex r5 P2-e).
    const sc = event?.structuredContent ?? event?.result?.structuredContent;
    const rc = typeof sc?.exit_code === "number" ? sc.exit_code
      : typeof sc?.exitCode === "number" ? sc.exitCode
      : typeof event?.details?.exitCode === "number" ? event.details.exitCode
      : event?.isError ? 1 : undefined;
    await runCC("post", {
      session_id: sessionID,
      tool_name: tool,
      tool_input: editInput(input),
      // One copy only: the oracle concatenates stdout + stderr + output, so sending the text twice doubled
      // every recorded out_sample ("okok", pi-live/tools.jsonl 2026-10-15) and made honest output fields fail
      // the #186 R1 comparison (found by the Pi replay arm, aidd-governance#186 P2-6).
      tool_response: { exit_code: rc, output: textOf(event).slice(0, 4000) },
    });
    return undefined;
  });

  pi.on("turn_end", async (event: any) => {
    const last = textOf(event?.message);
    if (!last || (event?.toolResults?.length ?? 0) > 0) return undefined; // not a final answer yet
    const v = await runCC("stop", { session_id: sessionID, last_assistant_message: last });
    if (v.decision === "block" && continuations < MAX_CONTINUATIONS) {
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
    }
    // aidd-governance#186 P1-4 (Pi live 2026-10-14 08:35Z): a release is never silent. Whether the
    // python side released by max-blocks (would_block) or this extension's continuation budget is
    // spent, the unverified claim gets a visible note in the session instead of passing unmarked.
    const note = v.decision === "block"
      ? "[H17] evidence unverified (continuation budget exhausted)"
      : v.would_block ? (v.note ?? "[H17] evidence unverified (max-blocks released)")
      : (v.note ?? null); // ADR-009: Status: partial / unverified passes with its note shown (Codex r2 P2)
    if (!note) return undefined;
    return {
      entries: [{ type: "custom_message", customType: "aidd-cc", display: true, content: `${note} — ${v.reason ?? ""}` }],
    };
  });
}
