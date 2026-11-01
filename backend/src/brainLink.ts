// Connects one phone session to the brain (the Python service in backend/app)
// over its WebSocket. Sends finished lines; receives decisions, whispers and photo tasks.
// The brain's message format is documented in backend/README.md.

import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { config } from "./config.js";
import type { Speaker } from "./protocol.js";

export type BrainEvent =
  /** `who_spoke` is "me", "them", "unknown" or "background"; `who_spoke_p` is Jev's confidence in it. */
  | { type: "transcript"; text: string; who_spoke: string | null; who_spoke_p?: number | null; cover_blown_risk: number | null }
  /** `text` is shown on the phone; `spoken` (a few words) is said in the ear. */
  | { type: "whisper"; id: string; text: string; spoken?: string; reason: "reply" | "task_done"; cover_blown_risk: number | null }
  | { type: "task_started"; task_id: string; task: string }
  | {
      type: "task_done";
      task_id: string;
      task: string;
      ok: boolean;
      image_url?: string;
      title?: string | null;
      query?: string;
      used_fallback?: boolean;
    }
  | { type: "persona"; persona: string }
  | { type: "error"; detail: unknown };

export interface BrainLinkEvents {
  event: (event: BrainEvent) => void;
  /** Fired once per outage, so the phone can say the brain is unreachable. */
  offline: (message: string) => void;
}

const RECONNECT_DELAY_MS = 1000;
const MAX_QUEUED = 20;

export class BrainLink extends EventEmitter {
  private ws: WebSocket | null = null;
  private queue: string[] = [];
  private closed = false;
  private reportedOffline = false;
  private reconnectTimer: NodeJS.Timeout | null = null;
  /** Sent again on every connect, because a restarted brain forgets it. */
  private personaMessage: string | null = null;

  constructor(private sessionId: string) {
    super();
    this.connect();
  }

  /** A finished line. "me"/"them" are trusted by the brain; "unknown" lets Jev decide. */
  sendTurn(text: string, speaker: Speaker) {
    const message = JSON.stringify({
      type: "transcript",
      text,
      speaker: speaker === "unknown" ? null : speaker,
      is_final: true,
    });
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(message);
      return;
    }
    this.queue.push(message);
    if (this.queue.length > MAX_QUEUED) this.queue.shift();
  }

  /** Who the wearer is playing. Takes effect before any line still in the queue. */
  setPersona(persona: string) {
    this.personaMessage = JSON.stringify({ type: "set_persona", persona });
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(this.personaMessage);
  }

  close() {
    this.closed = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
    this.ws = null;
  }

  private connect() {
    const url = new URL(config.brain.url);
    url.searchParams.set("session_id", this.sessionId);
    if (config.brain.token) url.searchParams.set("token", config.brain.token);

    const ws = new WebSocket(url);
    this.ws = ws;

    ws.on("open", () => {
      this.reportedOffline = false;
      if (this.personaMessage) ws.send(this.personaMessage);
      for (const message of this.queue) ws.send(message);
      this.queue = [];
    });

    ws.on("message", (data) => {
      try {
        this.emit("event", JSON.parse(data.toString()) as BrainEvent);
      } catch {
        // Not JSON; ignore.
      }
    });

    ws.on("error", (err) => {
      if (!this.reportedOffline) {
        this.reportedOffline = true;
        this.emit("offline", `Brain unreachable at ${config.brain.url}: ${err.message}`);
      }
    });

    ws.on("close", () => {
      if (this.ws === ws) this.ws = null;
      if (!this.closed) this.reconnectTimer = setTimeout(() => this.connect(), RECONNECT_DELAY_MS);
    });
  }

  override on<E extends keyof BrainLinkEvents>(event: E, listener: BrainLinkEvents[E]): this {
    return super.on(event, listener);
  }

  override emit<E extends keyof BrainLinkEvents>(event: E, ...args: Parameters<BrainLinkEvents[E]>): boolean {
    return super.emit(event, ...args);
  }
}
