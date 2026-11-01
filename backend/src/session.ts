// One connected phone: mic audio in -> Scribe -> Brain -> TTS -> whisper audio out.

import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { Brain } from "./brain/index.js";
import { config } from "./config.js";
import { ScribeSession } from "./ears/scribe.js";
import type { ClientMessage, ServerEvent, Speaker } from "./protocol.js";
import { speak, TTS_SAMPLE_RATE } from "./voice/tts.js";

/** Dashboards (mission-control screens) get a copy of every event. */
export const dashboards = new Set<WebSocket>();

export function broadcast(event: ServerEvent) {
  const json = JSON.stringify(event);
  for (const ws of dashboards) if (ws.readyState === ws.OPEN) ws.send(json);
}

export class PhoneSession {
  readonly id = randomUUID();
  private scribe = new ScribeSession();
  readonly brain: Brain;

  constructor(private ws: WebSocket) {
    this.brain = new Brain({
      send: (event) => this.send(event),
      say: (id, text) => this.say(id, text),
    });

    this.scribe.on("partial", (text) =>
      this.send({ type: "transcript", id: "partial", text, final: false, speaker: "unknown" }),
    );
    // Scribe speaker ids aren't reliably "me" vs "them"; the brain (Jev) decides.
    this.scribe.on("committed", (text) => this.onTurn(text, "unknown"));
    this.scribe.on("error", (message) => this.send({ type: "error", message }));

    let heardAudio = false;
    ws.on("message", (data, isBinary) => {
      if (isBinary) {
        if (!heardAudio) console.log(`[${this.id.slice(0, 8)}] receiving mic audio`);
        heardAudio = true;
        this.scribe.sendAudio(data as Buffer);
      } else {
        this.onJson(data.toString());
      }
    });
    ws.on("close", () => this.scribe.close());

    this.send({
      type: "ready",
      sessionId: this.id,
      integrations: {
        elevenlabs: !!config.elevenlabs.apiKey,
        jev: !!config.jev.apiKey,
        anthropic: !!config.anthropic.apiKey,
      },
    });
  }

  private onJson(raw: string) {
    let msg: ClientMessage;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (msg.type === "ping") this.send({ type: "pong" });
    if (msg.type === "debug_turn" && msg.text) this.onTurn(msg.text, msg.speaker ?? "them");
  }

  private onTurn(text: string, speaker: Speaker) {
    this.send({ type: "transcript", id: randomUUID(), text, final: true, speaker });
    void this.brain.onTurn(text, speaker).catch((err) => this.fail(err));
  }

  send(event: ServerEvent) {
    if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify(event));
    broadcast(event);
  }

  private async say(id: string, text: string) {
    this.send({ type: "whisper_audio_start", id, sampleRate: TTS_SAMPLE_RATE });
    try {
      await speak(text, (pcm) => {
        if (this.ws.readyState === this.ws.OPEN) this.ws.send(pcm, { binary: true });
      });
    } catch (err) {
      this.fail(err);
    } finally {
      this.send({ type: "whisper_audio_end", id });
    }
  }

  private fail(err: unknown) {
    console.error(err);
    this.send({ type: "error", message: err instanceof Error ? err.message : String(err) });
  }
}
