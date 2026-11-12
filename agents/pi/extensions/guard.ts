/**
 * Permissions for the local Pi (Pi has no permission system of its own).
 *
 * - bash: every command goes through agents/lib/guard.py (blocklist shared by
 *   the four agents). In the interactive profile, commands that are not simple
 *   reads ask for confirmation.
 * - write/edit outside the project: ask (interactive) or are blocked
 *   (autonomous, and whenever there is no UI).
 *
 * Variables: AGENT_PROFILE, AGENT_GUARD (path to guard.py), AGENT_WORKDIR.
 * Loaded with `pi -e <this file>` by run.sh and pi-local.
 */
import { spawnSync } from "node:child_process";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const READ_ONLY = new Set([
  "ls", "pwd", "cat", "head", "tail", "wc", "grep", "rg", "fd", "tree", "stat",
  "file", "which", "echo", "du", "diff", "sort", "uniq", "basename", "dirname",
]);
const GIT_READ_ONLY = new Set(["status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "blame", "grep"]);

function isSimpleReadOnly(command: string): boolean {
  if (/[;&|<>`\n]|\$\(/.test(command)) return false;
  const words = command.trim().split(/\s+/);
  const prog = path.basename(words[0] ?? "");
  if (prog === "git") return GIT_READ_ONLY.has(words[1] ?? "");
  if (prog === "find") return !/\s-(exec|execdir|ok|okdir|delete|fprint|fprintf|fls)\b/.test(command);
  return READ_ONLY.has(prog);
}

function runGuard(command: string, cwd: string): string | undefined {
  const guard = process.env.AGENT_GUARD;
  if (!guard) return "Blocked: local guard not configured (AGENT_GUARD is unset)";
  const r = spawnSync("python3", ["-I", guard], {
    input: JSON.stringify({ tool_name: "bash", tool_input: { command }, cwd }),
    encoding: "utf8",
    timeout: 15000,
  });
  if (r.status === 0) return undefined;
  if (r.status === 2) return (r.stderr || "Blocked by local policy").trim();
  return `Blocked: local guard failed (${r.status ?? r.signal}); command not executed`;
}

function isInside(target: string, root: string): boolean {
  const rel = path.relative(root, target);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

export default function (pi: ExtensionAPI) {
  const profile = process.env.AGENT_PROFILE ?? "autonomous";

  pi.on("tool_call", async (event, ctx) => {
    const root = process.env.AGENT_WORKDIR || ctx.cwd;
    const interactive = profile === "interactive" && ctx.hasUI;

    if (event.toolName === "bash") {
      const command = String((event.input as { command?: unknown }).command ?? "");
      const denied = runGuard(command, ctx.cwd);
      if (denied) return { block: true, reason: denied };
      if (interactive && !isSimpleReadOnly(command)) {
        const ok = await ctx.ui.confirm("Run command?", command);
        if (!ok) return { block: true, reason: "Blocked by the user" };
      }
      return undefined;
    }

    if (event.toolName === "write" || event.toolName === "edit") {
      const p = String((event.input as { path?: unknown }).path ?? "");
      const target = path.resolve(ctx.cwd, p);
      if (isInside(target, root)) return undefined;
      if (interactive) {
        const ok = await ctx.ui.confirm("Modify file outside the project?", target);
        if (ok) return undefined;
      }
      return { block: true, reason: `Blocked by local policy: writing outside the project (${target})` };
    }
    return undefined;
  });
}
