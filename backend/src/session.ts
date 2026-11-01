// One connected phone: mic audio in -> Scribe -> brain (Python) -> TTS -> whisper audio out.

import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { BrainLink, type BrainEvent } from "./brainLink.js";
import { config } from "./config.js";
import { ScribeSession } from "./ears/scribe.js";
import { cacheImage } from "./media.js";
import type { ClientMessage, ServerEvent, Speaker } from "./protocol.js";
import { speak, TTS_SAMPLE_RATE } from "./voice/tts.js";

/** How much quieter than the wearer a line must be to count as the other person. */
const ME_MARGIN_DB = 8;

/** Dashboards (mission-control screens) get a copy of every event. */
export const dashboards = new Set<WebSocket>();

export function broadcast(event: ServerEvent) {
  const json = JSON.stringify(event);
  for (const ws of dashboards) if (ws.readyState === ws.OPEN) ws.send(json);
}

export class PhoneSession {
  readonly id = randomUUID();
  private scribe = new ScribeSession();
  private brain = new BrainLink(this.id);
  /** How loud the wearer's own voice is in the mic, learned by "calibrate". */
  private myLevelDb: number | null = null;
  private calibrating = false;
  /** Lines sent to the brain and not yet echoed back, to match its verdict to our transcript id. */
  private pendingLines: { id: string; text: string; speaker: Speaker }[] = [];
  /** Whispers are spoken one after another, never over each other. */
  private speech: Promise<void> = Promise.resolve();
  /**
   * Brain events are handled in order. A photo is downloaded before its task_done goes out,
   * so the "photo's on your phone" whisper right behind it can't arrive before the photo.
   */
  private brainEvents: Promise<void> = Promise.resolve();

  /** `publicBaseUrl` is how the phone reaches this gateway over HTTP, for /media photo links. */
  constructor(
    private ws: WebSocket,
    private publicBaseUrl = `http://localhost:${config.port}`,
  ) {
    this.scribe.on("partial", (text) =>
      this.send({ type: "transcript", id: "partial", text, final: false, speaker: "unknown" }),
    );
    this.scribe.on("committed", (text, levelDb) => {
      if (this.calibrating) {
        this.calibrating = false;
        if (levelDb != null) this.myLevelDb = levelDb;
        this.send({ type: "calibrated", ok: levelDb != null, levelDb: levelDb ?? undefined });
        this.onTurn(text, "me");
        return;
      }
      const speaker = this.classify(levelDb);
      console.log(`[${this.id.slice(0, 8)}] ${speaker} (${levelDb?.toFixed(1) ?? "?"} dB): ${text}`);
      this.onTurn(text, speaker);
    });
    this.scribe.on("error", (message) => this.send({ type: "error", message }));

    this.brain.on("event", (event) => {
      this.brainEvents = this.brainEvents.then(() => this.onBrainEvent(event)).catch((err) => this.fail(err));
    });
    this.brain.on("offline", (message) => {
      console.warn(message);
      this.send({ type: "error", message: "Brain offline. Is the Python service running?" });
    });

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
    ws.on("close", () => {
      this.scribe.close();
      this.brain.close();
    });

    console.log(`[${this.id.slice(0, 8)}] phone connected (photos via ${publicBaseUrl})`);
    this.send({
      type: "ready",
      sessionId: this.id,
      integrations: { elevenlabs: !!config.elevenlabs.apiKey },
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
    if (msg.type === "calibrate") this.calibrating = true;
    if (msg.type === "set_persona" && msg.persona) this.brain.setPersona(msg.persona);
  }

  /** Lines within a few dB of the wearer's calibrated level are theirs; quieter ones are the other person. */
  private classify(levelDb: number | null): Speaker {
    if (levelDb == null || this.myLevelDb == null) return "unknown";
    return levelDb >= this.myLevelDb - ME_MARGIN_DB ? "me" : "them";
  }

  private onTurn(text: string, speaker: Speaker) {
    const id = randomUUID();
    this.send({ type: "transcript", id, text, final: true, speaker });
    this.pendingLines.push({ id, text, speaker });
    if (this.pendingLines.length > 20) this.pendingLines.shift();
    this.brain.sendTurn(text, speaker);
  }

  private async onBrainEvent(event: BrainEvent) {
    switch (event.type) {
      case "transcript": {
        // The brain echoes each line with Jev's verdict on who said it.
        const index = this.pendingLines.findIndex((line) => line.text === event.text.trim());
        const line = index >= 0 ? this.pendingLines.splice(index, 1)[0] : null;
        const verdict = event.who_spoke;
        if (line && line.speaker === "unknown" && (verdict === "me" || verdict === "them")) {
          this.send({ type: "transcript", id: line.id, text: line.text, final: true, speaker: verdict });
        }
        if (event.cover_blown_risk != null) this.send({ type: "risk", score: event.cover_blown_risk });
        return;
      }
      case "whisper":
        // Its risk score is the same decision already sent with the transcript echo.
        this.send({ type: "whisper", id: event.id, text: event.text });
        this.speech = this.speech.then(() => this.say(event.id, event.text));
        return;
      case "task_started":
        this.send({
          type: "task_started",
          id: event.task_id,
          kind: event.task === "find_photo" ? "find_photo" : "look_up_fact",
          label: event.task === "find_photo" ? "Finding a photo…" : "Looking it up…",
        });
        return;
      case "task_done": {
        // Serve the photo from here so the phone never hits a host that blocks it.
        let imageUrl = event.image_url;
        if (event.ok && imageUrl) {
          const id = await cacheImage(imageUrl);
          if (id) imageUrl = `${this.publicBaseUrl}/media/${id}`;
        }
        this.send({
          type: "task_done",
          id: event.task_id,
          kind: event.task === "find_photo" ? "find_photo" : "look_up_fact",
          ok: event.ok,
          imageUrl,
          caption: event.title ?? event.query,
        });
        return;
      }
      case "persona":
        console.log(`[${this.id.slice(0, 8)}] persona: ${event.persona}`);
        return;
      case "error":
        this.send({ type: "error", message: `Brain rejected a message: ${JSON.stringify(event.detail)}` });
        return;
    }
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
