// EARS (owner: Julian + Claude)
// Streams mic audio to ElevenLabs Scribe realtime and emits transcripts.
// Protocol: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime

import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { config } from "../config.js";

export interface ScribeEvents {
  partial: (text: string) => void;
  committed: (text: string, speakerId: string | null) => void;
  error: (message: string) => void;
}

const SAMPLE_RATE = 16000;
const MAX_QUEUED_CHUNKS = 50; // ~5 s of audio while (re)connecting

const URL_PARAMS = new URLSearchParams({
  model_id: "scribe_v2_realtime",
  audio_format: `pcm_${SAMPLE_RATE}`,
  commit_strategy: "vad",
  vad_silence_threshold_secs: "0.6",
  include_timestamps: "true",
});

export class ScribeSession extends EventEmitter {
  private ws: WebSocket | null = null;
  private queue: string[] = [];
  private closed = false;
  private lastCommitted = { text: "", at: 0 };

  /** Feed raw PCM16 mono 16 kHz audio from the phone. */
  sendAudio(pcm: Buffer): void {
    if (this.closed || !config.elevenlabs.apiKey) return;
    const message = JSON.stringify({
      message_type: "input_audio_chunk",
      audio_base_64: pcm.toString("base64"),
      commit: false,
      sample_rate: SAMPLE_RATE,
    });

    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(message);
      return;
    }
    this.queue.push(message);
    if (this.queue.length > MAX_QUEUED_CHUNKS) this.queue.shift();
    if (!this.ws) this.connect();
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
    this.ws = null;
  }

  private connect() {
    const ws = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${URL_PARAMS}`, {
      headers: { "xi-api-key": config.elevenlabs.apiKey },
    });
    this.ws = ws;

    ws.on("open", () => {
      for (const message of this.queue) ws.send(message);
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
    let msg: {
      message_type: string;
      text?: string;
      error?: string;
      words?: { type: string; speaker_id?: string | null }[] | null;
    };
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
      case "committed_transcript":
      case "committed_transcript_with_timestamps":
        this.onCommitted(msg.text ?? "", majoritySpeaker(msg.words));
        return;
      default:
        if (msg.error) this.emit("error", `Scribe ${msg.message_type}: ${msg.error}`);
    }
  }

  /** Both committed variants can arrive for one segment; emit it once. */
  private onCommitted(text: string, speakerId: string | null) {
    const trimmed = text.trim();
    if (!trimmed) return;
    const now = Date.now();
    if (trimmed === this.lastCommitted.text && now - this.lastCommitted.at < 3000) return;
    this.lastCommitted = { text: trimmed, at: now };
    this.emit("committed", trimmed, speakerId);
  }

  override on<E extends keyof ScribeEvents>(event: E, listener: ScribeEvents[E]): this {
    return super.on(event, listener);
  }

  override emit<E extends keyof ScribeEvents>(event: E, ...args: Parameters<ScribeEvents[E]>): boolean {
    return super.emit(event, ...args);
  }
}

function majoritySpeaker(words: { type: string; speaker_id?: string | null }[] | null | undefined): string | null {
  const counts = new Map<string, number>();
  for (const w of words ?? []) {
    if (w.type === "word" && w.speaker_id) counts.set(w.speaker_id, (counts.get(w.speaker_id) ?? 0) + 1);
  }
  let best: string | null = null;
  for (const [id, n] of counts) if (!best || n > counts.get(best)!) best = id;
  return best;
}
