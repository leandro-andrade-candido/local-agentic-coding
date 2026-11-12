/**
 * Records each request sent to the model as JSONL (AGENT_REQUEST_LOG).
 * Used to measure the preamble size (system prompt + tools) and to check
 * whether the prompt prefix stays stable across turns (llama-server cache).
 * Without AGENT_REQUEST_LOG the extension does nothing.
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
