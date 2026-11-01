import "dotenv/config";

const env = (key: string, fallback = "") => process.env[key]?.trim() || fallback;

export const config = {
  port: Number(env("PORT", "8787")),

  elevenlabs: {
    apiKey: env("ELEVENLABS_API_KEY"),
    voiceId: env("ELEVENLABS_VOICE_ID", "21m00Tcm4TlvDq8ikWAM"),
    ttsModel: env("ELEVENLABS_TTS_MODEL", "eleven_flash_v2_5"),
  },

  jev: {
    apiKey: env("JEV_API_KEY"),
  },

  anthropic: {
    apiKey: env("ANTHROPIC_API_KEY"),
    whisperModel: env("WHISPER_MODEL", "claude-haiku-5-5"),
  },

  tasks: {
    serpApiKey: env("SERPAPI_KEY"),
    agentboxdApiKey: env("AGENTBOXD_API_KEY"),
    agentboxdInbox: env("AGENTBOXD_INBOX"),
    photoEmailTo: env("PHOTO_EMAIL_TO"),
    fallbackPhotoUrl: env("FALLBACK_PHOTO_URL"),
  },
};

/** Logs which integrations are live vs. running in mock mode. */
export function logIntegrations() {
  const status = (on: boolean) => (on ? "live" : "mock");
  console.log(
    [
      `ElevenLabs: ${status(!!config.elevenlabs.apiKey)}`,
      `Jev: ${status(!!config.jev.apiKey)}`,
      `Anthropic: ${status(!!config.anthropic.apiKey)}`,
      `SerpAPI: ${status(!!config.tasks.serpApiKey)}`,
      `Agentboxd: ${status(!!config.tasks.agentboxdApiKey)}`,
    ].join(" | "),
  );
}
