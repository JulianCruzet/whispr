// EARS (owner: Julian + Claude)
// Streams mic audio to ElevenLabs Scribe realtime and emits transcripts.
// Skeleton: interface only. Real implementation lands in the ears-and-voice PR.

import { EventEmitter } from "node:events";

export interface ScribeEvents {
  partial: (text: string) => void;
  committed: (text: string, speakerId: string | null) => void;
  error: (message: string) => void;
}

export class ScribeSession extends EventEmitter {
  /** Feed raw PCM16 mono 16 kHz audio from the phone. */
  sendAudio(_pcm: Buffer): void {}

  close(): void {}

  override on<E extends keyof ScribeEvents>(event: E, listener: ScribeEvents[E]): this {
    return super.on(event, listener);
  }

  override emit<E extends keyof ScribeEvents>(event: E, ...args: Parameters<ScribeEvents[E]>): boolean {
    return super.emit(event, ...args);
  }
}
