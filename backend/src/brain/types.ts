import type { Speaker } from "../protocol.js";

export interface Turn {
  speaker: Speaker;
  text: string;
  at: number;
}
