// BRAIN (owner: Person B)
// Writes the one short line the user should say next.

import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import type { Turn } from "./types.js";

const SYSTEM = `You are Roxy, a handler whispering in an agent's earpiece during a live conversation.
The agent is bluffing (e.g. pretending to be a big fan of something) and must not get caught.
Reply with ONLY the exact words the agent should say next: one short, natural, casual line, at most 15 words.
No quotes, no stage directions, no explanations.`;

const client = config.anthropic.apiKey ? new Anthropic({ apiKey: config.anthropic.apiKey }) : null;

export async function writeLine(history: Turn[], persona: string): Promise<string> {
  if (!client) return mockLine(history);

  const transcript = history
    .slice(-12)
    .map((t) => `${t.speaker === "me" ? "AGENT" : t.speaker === "them" ? "THEM" : "?"}: ${t.text}`)
    .join("\n");

  const response = await client.messages.create({
    model: config.anthropic.whisperModel,
    max_tokens: 100,
    thinking: { type: "disabled" },
    output_config: { effort: "low" },
    system: SYSTEM,
    messages: [
      {
        role: "user",
        content: `Cover story: ${persona}\n\nConversation so far:\n${transcript}\n\nWhat does the agent say next?`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "text") return block.text.trim();
  }
  return mockLine(history);
}

function mockLine(history: Turn[]): string {
  const last = history.at(-1)?.text.toLowerCase() ?? "";
  if (/concert|show|live|tour/.test(last)) return "The Toronto show at Scotiabank. From The Start live wrecked me.";
  return "Honestly? Bewitched on vinyl changed my life.";
}
