// OpenCode 1.x plugin: passes every command of the bash tool through
// agents/lib/guard.py (blocklist shared by the five agents).
// Throwing an error in tool.execute.before cancels the call and returns the
// message to the model. A guard failure blocks the command (fail closed).
// Variables: AGENT_GUARD (path to guard.py), AGENT_PROFILE, AGENT_WORKDIR.
import { spawnSync } from "node:child_process"

export const LocalGuard = async ({ directory }) => {
  const guard = process.env.AGENT_GUARD
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const command = String(output.args?.command ?? "")
      if (!guard) throw new Error("Blocked: local guard not configured (AGENT_GUARD is unset)")
      const r = spawnSync("python3", ["-I", guard], {
        input: JSON.stringify({
          tool_name: "bash",
          tool_input: { command },
          cwd: output.args?.workdir || directory,
        }),
        encoding: "utf8",
        timeout: 15000,
      })
      if (r.status === 0) return
      if (r.status === 2) throw new Error((r.stderr || "Blocked by local policy").trim())
      throw new Error(`Blocked: local guard failed (${r.status ?? r.signal}); command not executed`)
    },
  }
}
