import "dotenv/config";

const env = (key: string, fallback = "") => process.env[key]?.trim() || fallback;

/** Where the brain (Python service) listens. On Render, BRAIN_HOSTPORT comes from the brain service. */
function brainUrl(): string {
  if (env("BRAIN_URL")) return env("BRAIN_URL");
  if (env("BRAIN_HOSTPORT")) return `ws://${env("BRAIN_HOSTPORT")}/ws`;
  return "ws://localhost:8000/ws";
}

export const config = {
  port: Number(env("PORT", "8787")),

  elevenlabs: {
    apiKey: env("ELEVENLABS_API_KEY"),
    voiceId: env("ELEVENLABS_VOICE_ID", "pFZP5JQG7iQjIQuC4Bku"),
    ttsModel: env("ELEVENLABS_TTS_MODEL", "eleven_flash_v2_5"),
  },

  brain: {
    url: brainUrl(),
    /** Same as the brain's APP_SHARED_TOKEN, if it requires one. */
    token: env("APP_SHARED_TOKEN"),
  },
};

export function logIntegrations() {
  console.log(`ElevenLabs: ${config.elevenlabs.apiKey ? "live" : "mock"} | brain: ${config.brain.url}`);
}
