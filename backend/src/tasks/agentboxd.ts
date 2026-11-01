// TASKS (owner: Person B)
// Emails the proof photo to the user's phone from the agent's Agentboxd inbox.
// TODO(Person B): implement with the Agentboxd SDK (`npm install agentboxd`),
// see the Agentboxd quickstart. Redeem code LARPHACKS-2026 first.

import { config } from "../config.js";

export async function emailPhoto(imageUrl: string, caption: string): Promise<boolean> {
  if (!config.tasks.agentboxdApiKey || !config.tasks.photoEmailTo) {
    console.log(`[agentboxd mock] would email ${imageUrl} ("${caption}")`);
    return false;
  }
  // TODO(Person B): send from config.tasks.agentboxdInbox to config.tasks.photoEmailTo.
  console.log(`[agentboxd] not implemented yet: ${imageUrl}`);
  return false;
}
