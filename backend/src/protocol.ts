// Wire protocol between the iPhone app and the backend.
// Keep this file and ios/Whispr/Net/Protocol.swift in sync. See docs/protocol.md.

/** Who said a line. "unknown" until the brain or Scribe tells them apart. */
export type Speaker = "me" | "them" | "unknown";

export type TaskKind = "find_photo" | "look_up_fact";

// ---------- phone -> backend ----------
// Binary frames: raw mic audio, PCM signed 16-bit little-endian, mono, 16 kHz.
// Text frames: JSON, one of:
export type ClientMessage =
  /** `deviceId` lets the gateway keep this phone's voice calibration across reconnects. */
  | { type: "hello"; device: string; sampleRate: number; deviceId?: string }
  /** Pretend someone said `text` (skips Scribe). For testing and as a demo fallback. */
  | { type: "debug_turn"; text: string; speaker?: Speaker }
  /** The next line spoken is `who` (default "me"): learn what their voice sounds like. */
  /** `seconds`: how much speech to collect (default ~4 s for me, ~3 s for them; up to 30). */
  | { type: "calibrate"; who?: "me" | "them"; seconds?: number }
  /** Forget both voice samples (calibrated or learnt), e.g. before a demo with new people. */
  | { type: "clear_calibration" }
  /** Stop a calibration in progress without keeping anything (the app's page was closed). */
  | { type: "cancel_calibration" }
  /** Who the wearer is playing: fan, interview, first_date or car_salesman. Default: fan. */
  | { type: "set_persona"; persona: string }
  /** Strict turn-taking for a rigged demo: the wearer first, then them, then the wearer... */
  | { type: "set_turns"; alternate: boolean }
  /** Turn-taking slipped: swap who is next. */
  | { type: "flip_turn" }
  /** Where the phone is playing a whisper, sent as each one starts (for the log). */
  | { type: "audio_state"; route: string; engine: boolean; listening: boolean }
  | { type: "ping" };

// ---------- backend -> phone (and dashboards) ----------
// Binary frames: whisper audio, PCM signed 16-bit little-endian, mono,
// at the sampleRate announced in the preceding "whisper_audio_start".
// Text frames: JSON, one of:
export type ServerEvent =
  | { type: "ready"; sessionId: string; integrations: Record<string, boolean> }
  | { type: "transcript"; id: string; text: string; final: boolean; speaker: Speaker }
  /** `reason` "photo_ready": the proof photo just landed. Show it with the photo, not over the line. */
  /** `text` is the full line; `spoken` is the short cue said in the ear, shown big on the phone. */
  | { type: "whisper"; id: string; text: string; spoken: string; reason: "reply" | "photo_ready" }
  | { type: "whisper_audio_start"; id: string; sampleRate: number }
  | { type: "whisper_audio_end"; id: string }
  | { type: "risk"; score: number }
  | { type: "task_started"; id: string; kind: TaskKind; label: string }
  | {
      type: "task_done";
      id: string;
      kind: TaskKind;
      ok: boolean;
      imageUrl?: string;
      caption?: string;
      emailed?: boolean;
    }
  /** Calibration progress: seconds `who` has talked so far, out of `target`. Sent live while they talk. */
  | { type: "calibrating"; who: "me" | "them"; seconds: number; target: number }
  /** `reason` says why a sample was refused: too little speech, or "them" sounded like the wearer. */
  | { type: "calibrated"; who: "me" | "them"; ok: boolean; reason?: "too_short" | "sounds_like_you" }
  | { type: "error"; message: string }
  /** With turn-taking on, who the next line will be labelled as (null when it's off). */
  | { type: "turn"; next: "me" | "them" | null }
  | { type: "pong" };
