// Superpowers bootstrap in the local OpenCode 1.x.
// Adapted from the official Superpowers plugin v6.4.1 (.opencode/plugins/superpowers.js,
// MIT, Jesse Vincent), part V1: the same experimental.chat.messages.transform hook
// puts the bootstrap at the start of the first user message. The skills themselves come
// from skills.paths (generated from AGENT_SKILLS_DIRS), not from this plugin.
// The text comes from AGENT_SKILLS_BOOTSTRAP_FILE (using-superpowers + opencode/superpowers-tools.md).
import { readFileSync } from "node:fs"

const MARKER = "superpowers:using-superpowers bootstrap"

let cached
function bootstrap() {
  if (cached !== undefined) return cached
  const file = process.env.AGENT_SKILLS_BOOTSTRAP_FILE
  try {
    cached = file ? readFileSync(file, "utf8") : null
  } catch {
    cached = null
  }
  return cached
}

async function isChildSession(client, sessionID) {
  // Subagents (task) do not restart the controller's flow (upstream #2160).
  if (!client || !sessionID) return false
  try {
    const res = await client.session.get({ path: { id: sessionID } })
    return Boolean((res?.data ?? res)?.parentID)
  } catch {
    return false
  }
}

export const SkillsBootstrap = async ({ client }) => ({
  "experimental.chat.messages.transform": async (_input, output) => {
    const text = bootstrap()
    if (!text || !output.messages.length) return
    const firstUser = output.messages.find((m) => m.info.role === "user")
    if (!firstUser || !firstUser.parts.length) return
    if (firstUser.parts.some((p) => p.type === "text" && typeof p.text === "string" && p.text.includes(MARKER))) return
    if (await isChildSession(client, firstUser.info.sessionID)) return
    const ref = firstUser.parts[0]
    firstUser.parts.unshift({ ...ref, type: "text", text })
  },
})
