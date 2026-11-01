// BRAIN (owner: Person B)
// Gets every finished turn, decides whether to whisper or start a task, and
// reports back through the callbacks. Knows nothing about audio or sockets.

import { randomUUID } from "node:crypto";
import type { ServerEvent, Speaker } from "../protocol.js";
import { emailPhoto } from "../tasks/agentboxd.js";
import { findPhoto } from "../tasks/findPhoto.js";
import { decide } from "./jev.js";
import type { Turn } from "./types.js";
import { writeLine, writeSearchQuery } from "./whisper.js";

const MIN_GAP_BETWEEN_WHISPERS_MS = 4000;
const WHISPER_THRESHOLD = 0.6;

export interface BrainOutput {
  /** Send an event to the phone (and dashboards). */
  send: (event: ServerEvent) => void;
  /** Speak a line into the user's ear. */
  say: (id: string, text: string) => Promise<void>;
}

export class Brain {
  private history: Turn[] = [];
  private lastWhisperAt = 0;
  /** Optional cover story; without one Roxy just plays along with their topic. */
  private persona = "";

  constructor(private out: BrainOutput) {}

  setPersona(persona: string) {
    this.persona = persona;
  }

  async onTurn(text: string, speaker: Speaker): Promise<void> {
    const turn: Turn = { speaker, text, at: Date.now() };
    this.history.push(turn);

    const decision = await decide(this.history, turn);
    this.out.send({ type: "risk", score: decision.risk });

    if (decision.task === "find_photo") {
      void this.runFindPhoto();
    }

    const cooledDown = Date.now() - this.lastWhisperAt > MIN_GAP_BETWEEN_WHISPERS_MS;
    if (decision.shouldWhisper >= WHISPER_THRESHOLD && cooledDown) {
      this.lastWhisperAt = Date.now();
      const id = randomUUID();
      const line = await writeLine(this.history, this.persona);
      if (!line) return;
      this.out.send({ type: "whisper", id, text: line });
      await this.out.say(id, line);
    }
  }

  private async runFindPhoto() {
    const id = randomUUID();
    const query = await writeSearchQuery(this.history, this.persona);
    this.out.send({ type: "task_started", id, kind: "find_photo", label: `Finding a photo: ${query}` });

    const photo = await findPhoto(query);
    const emailed = photo.imageUrl ? await emailPhoto(photo.imageUrl, photo.caption) : false;
    this.out.send({
      type: "task_done",
      id,
      kind: "find_photo",
      ok: !!photo.imageUrl,
      imageUrl: photo.imageUrl ?? undefined,
      caption: photo.caption,
      emailed,
    });
    if (photo.imageUrl) await this.out.say(randomUUID(), "Photo's on your phone.");
  }
}
