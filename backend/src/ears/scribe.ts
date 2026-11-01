// EARS (owner: Julian + Claude)
// Streams mic audio to ElevenLabs Scribe realtime and emits transcripts.
// Protocol: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
//
// Scribe realtime doesn't label speakers, so each committed line also carries
// how loud it was in the mic (dBFS). With headphones on, the wearer is much
// louder than the person across from them; session.ts uses that to tell them apart.

import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { config } from "../config.js";

export interface ScribeEvents {
  partial: (text: string) => void;
  committed: (text: string, levelDb: number | null) => void;
  error: (message: string) => void;
}

const SAMPLE_RATE = 16000;
const BYTES_PER_SECOND = SAMPLE_RATE * 2;
const MAX_QUEUED_CHUNKS = 50; // ~5 s of audio while (re)connecting
/** Scribe sends the plain commit just before the timestamped one; wait briefly for the latter. */
const TIMESTAMPS_GRACE_MS = 250;
const URL_PARAMS = new URLSearchParams({
  model_id: "scribe_v2_realtime",
  audio_format: `pcm_${SAMPLE_RATE}`,
  commit_strategy: "vad",
  vad_silence_threshold_secs: "0.6",
  include_timestamps: "true",
});

interface QueuedChunk {
  message: string;
  seconds: number;
  db: number;
}

interface Word {
  type: string;
  start?: number;
  end?: number;
}

export class ScribeSession extends EventEmitter {
  private ws: WebSocket | null = null;
  private queue: QueuedChunk[] = [];
  private closed = false;
  private lastCommitted = { text: "", at: 0 };
  private pendingPlain: NodeJS.Timeout | null = null;

  /** Seconds of audio sent in the current upstream session (Scribe's timestamps start at 0 per session). */
  private sentSeconds = 0;
  /** Loudness of each sent chunk, positioned on Scribe's timeline. */
  private levels: { start: number; end: number; db: number }[] = [];

  /** Feed raw PCM16 mono 16 kHz audio from the phone. */
  sendAudio(pcm: Buffer): void {
    if (this.closed || !config.elevenlabs.apiKey) return;
    const chunk: QueuedChunk = {
      message: JSON.stringify({
        message_type: "input_audio_chunk",
        audio_base_64: pcm.toString("base64"),
        commit: false,
        sample_rate: SAMPLE_RATE,
      }),
      seconds: pcm.length / BYTES_PER_SECOND,
      db: levelDb(pcm),
    };

    if (this.ws?.readyState === WebSocket.OPEN) {
      this.sendChunk(this.ws, chunk);
      return;
    }
    this.queue.push(chunk);
    if (this.queue.length > MAX_QUEUED_CHUNKS) this.queue.shift();
    if (!this.ws) this.connect();
  }

  close(): void {
    this.closed = true;
    if (this.pendingPlain) clearTimeout(this.pendingPlain);
    this.ws?.close();
    this.ws = null;
  }

  private sendChunk(ws: WebSocket, chunk: QueuedChunk) {
    ws.send(chunk.message);
    this.levels.push({ start: this.sentSeconds, end: this.sentSeconds + chunk.seconds, db: chunk.db });
    this.sentSeconds += chunk.seconds;
    if (this.levels.length > 3000) this.levels.splice(0, 1000); // ~5 min of history is plenty
  }

  private connect() {
    const ws = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${URL_PARAMS}`, {
      headers: { "xi-api-key": config.elevenlabs.apiKey },
    });
    this.ws = ws;

    ws.on("open", () => {
      this.sentSeconds = 0;
      this.levels = [];
      for (const chunk of this.queue) this.sendChunk(ws, chunk);
      this.queue = [];
    });

    ws.on("message", (data) => this.onMessage(data.toString()));

    ws.on("error", (err) => this.emit("error", `Scribe: ${err.message}`));

    // Sessions have a time limit; reconnect lazily on the next audio chunk.
    ws.on("close", () => {
      if (this.ws === ws) this.ws = null;
    });
  }

  private onMessage(raw: string) {
    let msg: { message_type: string; text?: string; error?: string; words?: Word[] | null };
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    switch (msg.message_type) {
      case "session_started":
        return;
      case "partial_transcript":
        if (msg.text) this.emit("partial", msg.text);
        return;
      case "committed_transcript": {
        // Fallback only: normally the timestamped version (with loudness) follows right away.
        const text = msg.text ?? "";
        if (this.pendingPlain) clearTimeout(this.pendingPlain);
        this.pendingPlain = setTimeout(() => this.onCommitted(text, null), TIMESTAMPS_GRACE_MS);
        return;
      }
      case "committed_transcript_with_timestamps": {
        if (this.pendingPlain) clearTimeout(this.pendingPlain);
        this.pendingPlain = null;
        const words = (msg.words ?? []).filter((w) => w.type === "word" && w.start != null && w.end != null);
        const level = words.length ? this.levelBetween(words[0].start!, words[words.length - 1].end!) : null;
        this.onCommitted(msg.text ?? "", level);
        return;
      }
      default:
        if (msg.error) this.emit("error", `Scribe ${msg.message_type}: ${msg.error}`);
    }
  }

  /** Average loudness of the audio between two points on Scribe's timeline. */
  private levelBetween(from: number, to: number): number | null {
    const inRange = this.levels.filter((l) => l.end > from && l.start < to);
    if (!inRange.length) return null;
    // Average energy, not dB, so pauses between words don't drag it down much.
    const meanPower = inRange.reduce((sum, l) => sum + 10 ** (l.db / 10), 0) / inRange.length;
    return 10 * Math.log10(meanPower);
  }

  /** Both committed variants can arrive for one segment; emit it once. */
  private onCommitted(text: string, levelDb: number | null) {
    const trimmed = text.trim();
    if (!trimmed) return;
    const now = Date.now();
    if (trimmed === this.lastCommitted.text && now - this.lastCommitted.at < 3000) return;
    this.lastCommitted = { text: trimmed, at: now };
    this.emit("committed", trimmed, levelDb);
  }

  override on<E extends keyof ScribeEvents>(event: E, listener: ScribeEvents[E]): this {
    return super.on(event, listener);
  }

  override emit<E extends keyof ScribeEvents>(event: E, ...args: Parameters<ScribeEvents[E]>): boolean {
    return super.emit(event, ...args);
  }
}

/** RMS loudness of PCM16 audio in dBFS (0 = max, about -90 = silence). */
export function levelDb(pcm: Buffer): number {
  const samples = Math.floor(pcm.length / 2);
  if (!samples) return -90;
  let sumSquares = 0;
  for (let i = 0; i < samples; i++) {
    const s = pcm.readInt16LE(i * 2) / 32768;
    sumSquares += s * s;
  }
  return Math.max(-90, 10 * Math.log10(sumSquares / samples + 1e-12));
}
