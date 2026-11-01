// One connected phone: mic audio in -> Scribe -> brain (Python) -> TTS -> whisper audio out.

import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { BrainLink, type BrainEvent } from "./brainLink.js";
import { config } from "./config.js";
import { ScribeSession, type Segment } from "./ears/scribe.js";
import { SpeakerModel, splitBySpeaker, type Who } from "./ears/speakers.js";
import { voiceprint } from "./ears/voiceprint.js";
import { cacheImage } from "./media.js";
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
  private brain = new BrainLink(this.id);
  /** Tells the wearer from the other person, from samples taken by "calibrate". */
  private speakers = new SpeakerModel();
  /** Whose voice the next finished line is a sample of, if calibrating. */
  private calibrating: Who | null = null;
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
    this.scribe.on("committed", (text, segment) => this.onCommitted(text, segment));
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
    if (msg.type === "calibrate") this.calibrating = msg.who === "them" ? "them" : "me";
    if (msg.type === "set_persona" && msg.persona) this.brain.setPersona(msg.persona);
  }

  private onCommitted(text: string, segment: Segment | null) {
    const tag = `[${this.id.slice(0, 8)}]`;
    const printOf = (from: number, to: number) => {
      const audio = this.scribe.audioBetween(from, to);
      return audio ? voiceprint(audio) : null;
    };
    const words = segment?.words.length ? segment.words : null;
    const print = words ? printOf(words[0].start, words[words.length - 1].end) : null;
    const levelDb = segment?.levelDb ?? null;

    if (this.calibrating) {
      const who = this.calibrating;
      this.calibrating = null;
      const ok = this.speakers.calibrate(who, print, levelDb);
      console.log(`${tag} calibrated ${who}: ${ok ? `${print?.seconds.toFixed(1) ?? "?"}s of speech` : "failed"}`);
      this.send({ type: "calibrated", who, ok });
      this.onTurn(text, who);
      return;
    }

    // A quick back-and-forth can arrive as one line: split it where the voice changes.
    const parts = words ? splitBySpeaker(words, printOf, this.speakers) : null;
    if (parts) {
      console.log(`${tag} split by voice: ${parts.map((p) => `${p.speaker}: ${p.text}`).join(" | ")}`);
      for (const part of parts) this.onTurn(part.text, part.speaker);
      return;
    }

    const verdict = this.speakers.classify(print, levelDb);
    const why =
      verdict.how === "voice"
        ? `voice ${verdict.position?.toFixed(2)}, ${print?.seconds.toFixed(1)}s`
        : verdict.how === "loudness"
          ? `loudness ${levelDb?.toFixed(1)} dB`
          : "not calibrated";
    console.log(`${tag} ${verdict.speaker} (${why}): ${text}`);
    this.onTurn(text, verdict.speaker);
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
