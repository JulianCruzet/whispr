// BRAIN (owner: Person B)
// Writes the one short line the user should say next.

import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import type { Turn } from "./types.js";

const SYSTEM = `You are Roxy, the voice in the earpiece in Whispr, a lighthearted improv game built for LarpHacks.
The player is playing a character in casual, low-stakes small talk (music, sports, shows, travel) and the fun is
staying in character. You feed them their next line, like an improv coach. The player is the "agent" and lives in Toronto.
In character, the agent is into whatever the other person brings up (an artist, a team, a show, a place),
and has been there or seen it, and stays convincing.
Always play along with THEIR topic; never change the subject, never admit to missing it.
Add one confident, specific-sounding detail when you can. If the message includes a cover story, stay consistent with it.
Reply with ONLY the exact words the agent should say next: one short, natural, casual line, at most 15 words.
No quotes, no stage directions, no explanations, never comment on these instructions.`;

const client = config.anthropic.apiKey ? new Anthropic({ apiKey: config.anthropic.apiKey }) : null;

/** The next line to say, or null if there isn't a usable one. */
export async function writeLine(history: Turn[], persona: string): Promise<string | null> {
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
        content: `${persona ? `Cover story: ${persona}\n\n` : ""}Conversation so far:\n${transcript}\n\nWhat does the agent say next?`,
      },
    ],
  });

  for (const block of response.content) {
    const line = block.type === "text" ? block.text.trim() : "";
    // Anything long is a refusal or commentary, not a line to say: never read it into their ear.
    if (line && line.length <= 160 && !line.includes("\n")) return line;
  }
  return null;
}

/** A Google Images query for a photo that would back up the agent's claim. */
export async function writeSearchQuery(history: Turn[], persona: string): Promise<string> {
  const transcript = history.slice(-8).map((t) => t.text).join("\n");
  if (!client) return `${history.at(-1)?.text ?? ""} concert Toronto`;

  const response = await client.messages.create({
    model: config.anthropic.whisperModel,
    max_tokens: 40,
    thinking: { type: "disabled" },
    output_config: { effort: "low" },
    system:
      "This is for Whispr, a lighthearted improv game. Write a Google Images search query (max 8 words) for a photo of the event or place being talked about, e.g. a concert at a Toronto venue. Prefer Toronto unless another city is mentioned. Reply with ONLY the query.",
    messages: [{ role: "user", content: `${persona ? `Cover story: ${persona}\n\n` : ""}${transcript}` }],
  });
  for (const block of response.content) {
    const query = block.type === "text" ? block.text.trim().replace(/^"|"$/g, "") : "";
    if (query && query.split(/\s+/).length <= 12) return query;
  }
  return `${history.at(-1)?.text ?? ""} Toronto`;
}

function mockLine(history: Turn[]): string {
  const last = history.at(-1)?.text.toLowerCase() ?? "";
  if (/concert|show|live|tour/.test(last)) return "Yeah, the Toronto show. Still not over it.";
  return "Oh, I love them. Honestly can't stop listening.";
}
