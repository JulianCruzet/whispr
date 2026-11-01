// One connected phone: mic audio in -> Scribe -> brain (Python) -> TTS -> whisper audio out.

import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { BrainLink, type BrainEvent } from "./brainLink.js";
import { config } from "./config.js";
import { ScribeSession, type Segment } from "./ears/scribe.js";
import { couldBeSameVoice, SpeakerModel, splitBySpeaker, type TimedWord, type Who } from "./ears/speakers.js";
import { voiceprint, type Voiceprint } from "./ears/voiceprint.js";
import { cacheImage } from "./media.js";
import type { ClientMessage, ServerEvent, Speaker } from "./protocol.js";
import { speak, TTS_SAMPLE_RATE } from "./voice/tts.js";

/**
 * Calibration listens across lines until the person has talked this long (from Scribe's
 * word times, so it matches how long they spoke). The wearer's sample is what every line
 * is measured against, so it gets the longer one.
 */
const CALIBRATION_TARGET_SECONDS: Record<Who, number> = { me: 6, them: 5 };
/** Learning a voice from Jev's verdicts needs this much speech in the sample itself. */
const LEARN_TARGET_SECONDS: Record<Who, number> = { me: 4, them: 3 };
/** How often the live calibration progress goes to the phone while someone talks. */
const PROGRESS_EVERY_MS = 250;
/** ...and gives up after this many lines, keeping the sample if it has at least the minimum. */
const CALIBRATION_MAX_LINES = 4;
/** A longer calibration the phone asks for (say 15 s for a demo) is capped at this. */
const CALIBRATION_LONGEST_SECONDS = 30;
const CALIBRATION_MIN_SECONDS = 1.5;
/** Without calibration, lines Jev is at least this sure about teach the gateway that voice. */
const LEARN_MIN_P = 0.8;
/** Noise Scribe writes out instead of words, like "(background noise)" or "[music]". */
const NOISE_TAGS = /\([^)]*\)|\[[^\]]*\]/g;
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
  private calibrating: {
    who: Who;
    target: number;
    maxLines: number;
    maxSkips: number;
    audio: Buffer[];
    lines: number;
    skipped: number;
    levels: number[];
    /** Seconds talked in the lines kept so far. */
    talked: number;
    /** When Scribe started hearing the line in progress (ms), for live progress. */
    lineStartedAt: number | null;
    lastProgressAt: number;
  } | null = null;
  /** Lines sent to the brain and not yet echoed back, to match its verdict to our transcript id. */
  /** Lines waiting for Jev's verdict; `audio` is kept for unplaced lines, to learn the voice. */
  private pendingLines: { id: string; text: string; speaker: Speaker; audio: Buffer | null }[] = [];
  /** Uncalibrated voices, learnt from lines Jev is sure about (see `learnVoice`). */
  private learning: Record<Who, Buffer[]> = { me: [], them: [] };
  /** Lines in a row that didn't match the voice being learnt; two mean the start was wrong. */
  private learningMisses: Record<Who, number> = { me: 0, them: 0 };
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
    this.scribe.on("partial", (text) => {
      // Calibration is set apart from the conversation: only its progress goes to the phone.
      if (this.calibrating) this.liveProgress();
      else this.send({ type: "transcript", id: "partial", text, final: false, speaker: "unknown" });
    },
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
      const who: Who = msg.who === "them" ? "them" : "me";
      const asked = Number(msg.seconds);
      const long = Number.isFinite(asked) && asked > CALIBRATION_TARGET_SECONDS[who];
      const target = long ? Math.min(asked, CALIBRATION_LONGEST_SECONDS) : CALIBRATION_TARGET_SECONDS[who];
      // A long one (the app's calibration page) runs as many lines as it takes. There the
      // person talking is chosen on purpose, so none of their lines is second-guessed as the
      // wearer's: with two real voices that threw away whole 15 s lines. The final
      // sounds-like-you check still refuses a sample that is really the wearer.
      this.calibrating = {
        who,
        target,
        maxLines: long ? Math.ceil(target) * 2 : CALIBRATION_MAX_LINES,
        maxSkips: long ? 0 : 2,
        audio: [],
        lines: 0,
        skipped: 0,
        levels: [],
        talked: 0,
        lineStartedAt: null,
        lastProgressAt: 0,
      };
    }
    if (msg.type === "cancel_calibration") this.calibrating = null;
    if (msg.type === "clear_calibration") {
      this.calibrating = null;
      this.speakers.reset();
      this.learning = { me: [], them: [] };
      this.learningMisses = { me: 0, them: 0 };
      console.log(`[${this.id.slice(0, 8)}] cleared both voices`);
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
    if (sampling.who === "them" && sampling.skipped < sampling.maxSkips && print && this.speakers.couldBe("me", print)) {
      sampling.skipped++;
      sampling.lineStartedAt = null;
      console.log(`${tag} calibrating them: skipped a line in the wearer's voice`);
      // The live bar counted this line; put it back.
      this.send({ type: "calibrating", who: sampling.who, seconds: sampling.talked, target: sampling.target });
      return;
    }

    const audio = words ? this.scribe.audioBetween(words[0].start, words[words.length - 1].end) : null;
    if (audio) sampling.audio.push(audio);
    if (levelDb !== null) sampling.levels.push(levelDb);
    sampling.lines++;
    if (words) sampling.talked += words[words.length - 1].end - words[0].start;
    sampling.lineStartedAt = null;
    const sample = sampling.audio.length ? voiceprint(Buffer.concat(sampling.audio), this.scribe.noiseFloorDb()) : null;
    // `seconds` is speech in the sample itself (pauses and breaths don't count).
    const seconds = sample?.seconds ?? 0;
    const { target, talked } = sampling;
    // Never sent to the brain: calibration is practice talk, not the conversation, and
    // a line from "them" there would get a whisper.
    this.send({ type: "calibrating", who: sampling.who, seconds: talked, target });

    if (talked < target && sampling.lines < sampling.maxLines) return;
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
    const heard = `${talked.toFixed(1)}s talking, ${seconds.toFixed(1)}s of voice`;
    console.log(`${tag} calibrated ${sampling.who}: ${ok ? `${heard} from ${sampling.lines} lines` : `failed (${reason ?? "unusable"}, ${heard})`}`);
    this.send({ type: "calibrated", who: sampling.who, ok, ...(ok ? {} : { reason: reason ?? "too_short" }) });
  }

  private onCommitted(text: string, segment: Segment | null) {
    const tag = `[${this.id.slice(0, 8)}]`;
    // Scribe writes noise out as tags; a line that's only noise isn't anyone talking.
    const spoken = text.replace(NOISE_TAGS, " ").replace(/\s+/g, " ").trim();
    if (!/[a-z0-9]/i.test(spoken)) {
      console.log(`${tag} ignored noise: ${text}`);
      return;
    }
    text = spoken;
    if (segment) segment = { ...segment, words: segment.words.filter((w) => !/[()[\]]/.test(w.text)) };
    const printOf = (from: number, to: number) => {
      const audio = this.scribe.audioBetween(from, to);
      return audio ? voiceprint(audio, this.scribe.noiseFloorDb()) : null;
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
    const audio = verdict.speaker === "unknown" && words ? this.scribe.audioBetween(words[0].start, words[words.length - 1].end) : null;
    this.onTurn(text, verdict.speaker, audio);
  }

  /** While someone talks during calibration, moves the bar before Scribe finishes the line. */
  private liveProgress() {
    const sampling = this.calibrating!;
    const now = Date.now();
    sampling.lineStartedAt ??= now;
    if (now - sampling.lastProgressAt < PROGRESS_EVERY_MS) return;
    sampling.lastProgressAt = now;
    const seconds = Math.min(sampling.talked + (now - sampling.lineStartedAt) / 1000, sampling.target);
    this.send({ type: "calibrating", who: sampling.who, seconds, target: sampling.target });
  }

  /**
   * Without calibration, learns a voice from lines Jev is sure about: once there's as much
   * speech as calibration would take, it becomes that voice's sample.
   */
  private learnVoice(who: Who, audio: Buffer) {
    if (this.calibrating || this.speakers.calibrated[who]) return;
    const print = voiceprint(audio, this.scribe.noiseFloorDb());
    if (!print || print.seconds < 1) return;
    // The other person's voice must not catch the wearer's.
    if (who === "them" && this.speakers.couldBe("me", print)) return;
    const sofar = this.learning[who].length ? voiceprint(Buffer.concat(this.learning[who]), this.scribe.noiseFloorDb()) : null;
    if (sofar && sofar.seconds >= CALIBRATION_MIN_SECONDS && !couldBeSameVoice(print, sofar)) {
      // Two misses in a row: the lines learnt so far were probably the wrong voice.
      if (++this.learningMisses[who] < 2) return;
      this.learning[who] = [];
    }
    this.learningMisses[who] = 0;
    this.learning[who].push(audio);
    const sample = voiceprint(Buffer.concat(this.learning[who]), this.scribe.noiseFloorDb());
    if (!sample || sample.seconds < LEARN_TARGET_SECONDS[who]) return;
    const lines = this.learning[who].length;
    this.learning[who] = [];
    if (who === "them" && this.speakers.soundsLike("me", sample)) return;
    if (this.speakers.calibrate(who, sample, null)) {
      console.log(`[${this.id.slice(0, 8)}] learnt ${who}'s voice from ${lines} lines Jev was sure of (${sample.seconds.toFixed(1)}s)`);
    }
  }

  private onTurn(text: string, speaker: Speaker, audio: Buffer | null = null) {
    const id = randomUUID();
    this.send({ type: "transcript", id, text, final: true, speaker });
    this.pendingLines.push({ id, text, speaker, audio });
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
          if (line.audio && (event.who_spoke_p ?? 0) >= LEARN_MIN_P) this.learnVoice(verdict, line.audio);
        }
        if (verdict === "background") console.log(`[${this.id.slice(0, 8)}] background, ignored: ${event.text}`);
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
        // The ear gets the short cue; the full line is on the screen.
        this.speech = this.speech.then(() => this.say(event.id, event.spoken || event.text));
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
