/**
 * Grava cada requisição enviada ao modelo em JSONL (AGENT_REQUEST_LOG).
 * Serve para medir o tamanho do preâmbulo (system prompt + ferramentas) e
 * conferir se o prefixo do prompt fica estável entre turnos (cache do llama-server).
 * Sem AGENT_REQUEST_LOG a extensão não faz nada.
 */
import { appendFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const file = process.env.AGENT_REQUEST_LOG;
  if (!file) return;
  pi.on("before_provider_request", (event) => {
    appendFileSync(file, `${JSON.stringify({ ts: new Date().toISOString(), payload: event.payload })}\n`, "utf8");
    return undefined;
  });
}
