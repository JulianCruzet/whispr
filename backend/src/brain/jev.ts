// BRAIN (owner: Person B)
// Jev (TypeSafe AI) makes the fast yes/no and routing calls on every finished turn.
// API shape from third-party write-ups; verify against https://docs.typesafe.ai/api.

import { config } from "../config.js";
import type { Speaker, TaskKind } from "../protocol.js";
import type { Turn } from "./types.js";

export interface Decision {
  /** 0..1: does the user need a line right now? */
  shouldWhisper: number;
  /** Who said the latest turn. */
  speaker: Speaker;
  /** Background task to start, if any. */
  task: TaskKind | null;
  /** 0..1: how close the user is to getting caught. */
  risk: number;
}

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";

export async function decide(history: Turn[], latest: Turn): Promise<Decision> {
  if (!config.jev.apiKey) return mockDecide(latest);

  const state = history
    .slice(-8)
    .map((t) => `${t.speaker}: ${t.text}`)
    .join("\n");

  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.jev.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "jev-latest",
      state,
      questions: {
        should_whisper: {
          type: "noul",
          instructions:
            "The user is bluffing in this conversation. Did the other person just say something the user must answer right now (a question, a challenge, or a claim to react to)?",
        },
        launch_task: {
          type: "choice",
          instructions: "Would showing proof help the user's bluff right now?",
          criteria: {
            none: "No proof needed.",
            find_photo: "A photo (e.g. from a concert, trip or event) would back up the user's claim.",
            look_up_fact: "The user needs a specific fact (date, name, number) to stay convincing.",
          },
        },
        cover_blown: {
          type: "noul",
          instructions: "Is the other person getting suspicious that the user is faking it?",
        },
      },
    }),
  });

  if (!res.ok) {
    console.warn(`Jev ${res.status}: falling back to mock decision`);
    return mockDecide(latest);
  }

  const data = (await res.json()) as {
    answers: {
      should_whisper?: { noul: number };
      launch_task?: { choice: string };
      cover_blown?: { noul: number };
    };
  };
  const choice = data.answers.launch_task?.choice;
  return {
    shouldWhisper: data.answers.should_whisper?.noul ?? 0,
    speaker: latest.speaker,
    task: choice === "find_photo" || choice === "look_up_fact" ? choice : null,
    risk: data.answers.cover_blown?.noul ?? 0,
  };
}

/** Keyword heuristics so the pipeline runs end to end before keys arrive. */
function mockDecide(latest: Turn): Decision {
  const text = latest.text.toLowerCase();
  const fromThem = latest.speaker !== "me";
  const wantsProof = /\b(concert|show|tour|live|were you there|pics?|photos?|proof)\b/.test(text);
  return {
    shouldWhisper: fromThem && (text.includes("?") || wantsProof) ? 0.9 : 0.1,
    speaker: latest.speaker,
    task: fromThem && wantsProof ? "find_photo" : null,
    risk: /\b(really|sure|prove|fake|lying)\b/.test(text) ? 0.7 : 0.2,
  };
}
