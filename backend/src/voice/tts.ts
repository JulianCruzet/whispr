// VOICE (owner: Julian + Claude)
// Turns a whisper line into speech with ElevenLabs Flash and streams PCM chunks.
// Skeleton: interface only. Real implementation lands in the ears-and-voice PR.

export const TTS_SAMPLE_RATE = 24000;

/**
 * Speaks `text`, calling `onChunk` with PCM16 mono chunks at TTS_SAMPLE_RATE.
 * Resolves when the audio is fully streamed. Resolves immediately (no audio)
 * when ElevenLabs isn't configured, so the phone just shows the text.
 */
export async function speak(_text: string, _onChunk: (pcm: Buffer) => void): Promise<void> {}
