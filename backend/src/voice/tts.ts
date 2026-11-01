// VOICE (owner: Julian + Claude)
// Turns a whisper line into speech with ElevenLabs Flash and streams PCM chunks
// as they arrive, so playback starts before the whole line is generated.

import { config } from "../config.js";

export const TTS_SAMPLE_RATE = 24000;
/** Whispers are spoken in turn, so a stalled request would silence every one after it. */
const TTS_TIMEOUT_MS = 15_000;

/**
 * Speaks `text`, calling `onChunk` with PCM16 mono chunks at TTS_SAMPLE_RATE.
 * Resolves when the audio is fully streamed. Without an ElevenLabs key it plays
 * a short soft chime instead, so the phone's playback path can still be tested.
 */
export async function speak(text: string, onChunk: (pcm: Buffer) => void): Promise<void> {
  if (!config.elevenlabs.apiKey) {
    onChunk(chime());
    return;
  }

  const { voiceId, ttsModel, apiKey } = config.elevenlabs;
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}/stream?output_format=pcm_${TTS_SAMPLE_RATE}`,
    {
      method: "POST",
      headers: { "xi-api-key": apiKey, "Content-Type": "application/json" },
      body: JSON.stringify({ text, model_id: ttsModel }),
      signal: AbortSignal.timeout(TTS_TIMEOUT_MS),
    },
  );
  if (!res.ok || !res.body) {
    throw new Error(`ElevenLabs TTS ${res.status}: ${await res.text().catch(() => "")}`);
  }

  // Forward only whole 16-bit samples; carry an odd trailing byte to the next chunk.
  let carry: Buffer | null = null;
  for await (const part of res.body) {
    let chunk = Buffer.from(part);
    if (carry) {
      chunk = Buffer.concat([carry, chunk]);
      carry = null;
    }
    if (chunk.length % 2 === 1) {
      carry = chunk.subarray(chunk.length - 1);
      chunk = chunk.subarray(0, chunk.length - 1);
    }
    if (chunk.length) onChunk(chunk);
  }
}

/** 250 ms two-note chime, PCM16 mono at TTS_SAMPLE_RATE. */
function chime(): Buffer {
  const samples = Math.floor(TTS_SAMPLE_RATE * 0.25);
  const buf = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) {
    const t = i / TTS_SAMPLE_RATE;
    const freq = t < 0.12 ? 880 : 1320;
    const envelope = Math.sin((Math.PI * i) / samples);
    buf.writeInt16LE(Math.round(Math.sin(2 * Math.PI * freq * t) * envelope * 6000), i * 2);
  }
  return buf;
}
