// Bootstrap do Superpowers no OpenCode 1.x local.
// Adaptado do plugin oficial do Superpowers v6.4.1 (.opencode/plugins/superpowers.js,
// MIT, Jesse Vincent), parte V1: o mesmo gancho experimental.chat.messages.transform
// põe o bootstrap no início da primeira mensagem do usuário. As skills em si vêm de
// skills.paths (gerado a partir de AGENT_SKILLS_DIRS), não deste plugin.
// O texto vem de AGENT_SKILLS_BOOTSTRAP_FILE (using-superpowers + opencode/superpowers-tools.md).
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
  // Subagentes (task) não reiniciam o fluxo do controlador (upstream #2160).
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
