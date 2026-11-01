// One connected phone: mic audio in -> Scribe -> brain (Python) -> TTS -> whisper audio out.

import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { BrainLink, type BrainEvent } from "./brainLink.js";
import { config } from "./config.js";
import { ScribeSession, type Segment } from "./ears/scribe.js";
import { SpeakerModel, splitBySpeaker, type TimedWord, type Who } from "./ears/speakers.js";
import { voiceprint, type Voiceprint } from "./ears/voiceprint.js";
import { cacheImage } from "./media.js";
import type { ClientMessage, ServerEvent, Speaker } from "./protocol.js";
import { speak, TTS_SAMPLE_RATE } from "./voice/tts.js";

/**
 * Calibration listens across lines until it has this much of the person's speech. The
 * wearer's sample is what every line is measured against, so it gets the longer one.
 */
const CALIBRATION_TARGET_SECONDS: Record<Who, number> = { me: 4, them: 3 };
/** ...and gives up after this many lines, keeping the sample if it has at least the minimum. */
const CALIBRATION_MAX_LINES = 4;
const CALIBRATION_MIN_SECONDS = 1.5;
/** Each phone's voice samples, kept across reconnects (a tunnel blip shouldn't mean recalibrating). */
const savedSpeakers = new Map<string, SpeakerModel>();

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
  /** Calibration in progress: whose voice, and the audio collected from their lines so far. */
  private calibrating: { who: Who; audio: Buffer[]; lines: number; skipped: number; levels: number[] } | null = null;
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
    if (msg.type === "calibrate") {
      this.calibrating = { who: msg.who === "them" ? "them" : "me", audio: [], lines: 0, skipped: 0, levels: [] };
    }
    if (msg.type === "hello" && msg.deviceId) this.restoreSpeakers(msg.deviceId);
    if (msg.type === "set_persona" && msg.persona) this.brain.setPersona(msg.persona);
  }

  /** Uses this phone's saved voice samples, if it calibrated before; tells the app what's already done. */
  private restoreSpeakers(deviceId: string) {
    const saved = savedSpeakers.get(deviceId);
    if (saved) {
      this.speakers = saved;
      const { me, them } = saved.calibrated;
      console.log(`[${this.id.slice(0, 8)}] restored calibration (me ${me}, them ${them})`);
      if (me) this.send({ type: "calibrated", who: "me", ok: true });
      if (them) this.send({ type: "calibrated", who: "them", ok: true });
    } else {
      savedSpeakers.set(deviceId, this.speakers);
    }
  }

  /**
   * One line toward a calibration sample. Lines add up until there's enough speech, so a
   * short "yeah, hi" doesn't make a bad sample. While sampling the other person, lines in
   * the wearer's voice ("go on, say something") are left out.
   */
  private collectSample(text: string, words: TimedWord[] | null, print: Voiceprint | null, levelDb: number | null) {
    const tag = `[${this.id.slice(0, 8)}]`;
    const sampling = this.calibrating!;
    // Their sample must not catch the wearer prompting them, so skip any line that isn't
    // clearly another voice: skipping one of theirs only costs a line. At most two, in case
    // the two voices are simply very alike.
    if (sampling.who === "them" && sampling.skipped < 2 && print && this.speakers.couldBe("me", print)) {
      sampling.skipped++;
      console.log(`${tag} calibrating them: skipped a line in the wearer's voice`);
      this.onTurn(text, "me");
      return;
    }

    const audio = words ? this.scribe.audioBetween(words[0].start, words[words.length - 1].end) : null;
    if (audio) sampling.audio.push(audio);
    if (levelDb !== null) sampling.levels.push(levelDb);
    sampling.lines++;
    const sample = sampling.audio.length ? voiceprint(Buffer.concat(sampling.audio)) : null;
    const seconds = sample?.seconds ?? 0;
    const target = CALIBRATION_TARGET_SECONDS[sampling.who];
    this.send({ type: "calibrating", who: sampling.who, seconds, target });
    this.onTurn(text, sampling.who);

    if (seconds < target && sampling.lines < CALIBRATION_MAX_LINES) return;
    this.calibrating = null;
    const level = sampling.levels.length ? sampling.levels.reduce((a, b) => a + b, 0) / sampling.levels.length : null;
    // A "them" sample that is really the wearer would turn every line into a coin toss.
    const reason =
      seconds < CALIBRATION_MIN_SECONDS || !sample
        ? "too_short"
        : sampling.who === "them" && this.speakers.soundsLike("me", sample)
          ? "sounds_like_you"
          : null;
    const ok = reason === null && this.speakers.calibrate(sampling.who, sample, level);
    console.log(`${tag} calibrated ${sampling.who}: ${ok ? `${seconds.toFixed(1)}s from ${sampling.lines} lines` : `failed (${reason ?? "unusable"}, ${seconds.toFixed(1)}s)`}`);
    this.send({ type: "calibrated", who: sampling.who, ok, ...(ok ? {} : { reason: reason ?? "too_short" }) });
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
      this.collectSample(text, words, print, levelDb);
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
        this.send({
          type: "whisper",
          id: event.id,
          text: event.text,
          reason: event.reason === "task_done" ? "photo_ready" : "reply",
        });
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
