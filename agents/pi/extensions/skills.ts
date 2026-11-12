/**
 * Skills and Superpowers bootstrap in the local Pi.
 *
 * Adapted from the official Superpowers extension v6.4.1 (.pi/extensions/superpowers.ts,
 * MIT, Jesse Vincent): instead of the package's skills/ folder, it hands Pi the
 * directories in AGENT_SKILLS_RESOLVED (lib/skills.py) and injects the bootstrap
 * generated in AGENT_SKILLS_BOOTSTRAP_FILE (using-superpowers + pi/superpowers-tools.md).
 *
 * - resources_discover: the directories become native Pi skills (only name and
 *   description in the prompt; the body is read on demand; `/skill:name` forces it).
 * - context: inserts the bootstrap as the first user message at the start of each
 *   session and after compaction, only once.
 */
import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BOOTSTRAP_MARKER = "superpowers:using-superpowers bootstrap";

function readBootstrap(): string | null {
	const file = process.env.AGENT_SKILLS_BOOTSTRAP_FILE;
	if (!file) return null;
	try {
		return readFileSync(file, "utf8");
	} catch {
		return null;
	}
}

function messageContainsBootstrap(message: unknown): boolean {
	const content = (message as { content?: unknown }).content;
	if (typeof content === "string") return content.includes(BOOTSTRAP_MARKER);
	if (!Array.isArray(content)) return false;
	return content.some(
		(part) =>
			part &&
			typeof part === "object" &&
			(part as { type?: unknown }).type === "text" &&
			typeof (part as { text?: unknown }).text === "string" &&
			(part as { text: string }).text.includes(BOOTSTRAP_MARKER),
	);
}

function firstNonCompactionSummaryIndex(messages: unknown[]): number {
	let index = 0;
	while ((messages[index] as { role?: unknown } | undefined)?.role === "compactionSummary") index += 1;
	return index;
}

export default function (pi: ExtensionAPI) {
	const skillPaths = (process.env.AGENT_SKILLS_RESOLVED ?? "").split(":").filter(Boolean);
	const bootstrap = readBootstrap();
	let injectBootstrap = true;

	pi.on("resources_discover", async () => ({ skillPaths }));

	if (!bootstrap) return;

	pi.on("session_start", async () => {
		injectBootstrap = true;
	});
	pi.on("session_compact", async () => {
		injectBootstrap = true;
	});
	pi.on("agent_end", async () => {
		injectBootstrap = false;
	});

	pi.on("context", async (event) => {
		if (!injectBootstrap) return;
		if (event.messages.some(messageContainsBootstrap)) return;
		const bootstrapMessage = {
			role: "user" as const,
			content: [{ type: "text" as const, text: bootstrap }],
			timestamp: Date.now(),
		};
		const insertAt = firstNonCompactionSummaryIndex(event.messages);
		return {
			messages: [...event.messages.slice(0, insertAt), bootstrapMessage, ...event.messages.slice(insertAt)],
		};
	});
}
