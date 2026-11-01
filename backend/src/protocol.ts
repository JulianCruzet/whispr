// Wire protocol between the iPhone app and the backend.
// Keep this file and ios/Whispr/Net/Protocol.swift in sync. See docs/protocol.md.

/** Who said a line. "unknown" until the brain or Scribe tells them apart. */
export type Speaker = "me" | "them" | "unknown";

export type TaskKind = "find_photo" | "look_up_fact";

// ---------- phone -> backend ----------
// Binary frames: raw mic audio, PCM signed 16-bit little-endian, mono, 16 kHz.
// Text frames: JSON, one of:
export type ClientMessage =
  | { type: "hello"; device: string; sampleRate: number }
  /** Pretend someone said `text` (skips Scribe). For testing and as a demo fallback. */
  | { type: "debug_turn"; text: string; speaker?: Speaker }
  /** The next line spoken is `who` (default "me"): learn what their voice sounds like. */
  | { type: "calibrate"; who?: "me" | "them" }
  /** Who the wearer is playing: fan, interview, first_date or car_salesman. Default: fan. */
  | { type: "set_persona"; persona: string }
  | { type: "ping" };

// ---------- backend -> phone (and dashboards) ----------
// Binary frames: whisper audio, PCM signed 16-bit little-endian, mono,
// at the sampleRate announced in the preceding "whisper_audio_start".
// Text frames: JSON, one of:
export type ServerEvent =
  | { type: "ready"; sessionId: string; integrations: Record<string, boolean> }
  | { type: "transcript"; id: string; text: string; final: boolean; speaker: Speaker }
  | { type: "whisper"; id: string; text: string }
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
  | { type: "calibrated"; who: "me" | "them"; ok: boolean }
  | { type: "error"; message: string }
  | { type: "pong" };
