// Proof photos for the phone. The gateway downloads each photo once and serves it from
// /media/<id>, because many image hosts refuse the iPhone app's requests, and the brain's
// cached photo may be on an address only the backend can reach.

import { randomUUID } from "node:crypto";

const FETCH_TIMEOUT_MS = 4000;
const MAX_BYTES = 15 * 1024 * 1024;
/** Photos kept in memory; older ones are dropped. */
const KEEP = 30;

// Same reason as the brain's photo search: hosts like Wikimedia answer non-browser clients with 403.
const IMAGE_HEADERS = {
  "User-Agent":
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 " +
    "(KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1",
  Accept: "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8",
};

export interface CachedImage {
  body: Buffer;
  contentType: string;
}

const images = new Map<string, CachedImage>();

/** Downloads an image and returns its id under /media, or null if it isn't a usable image. */
export async function cacheImage(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { headers: IMAGE_HEADERS, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    const contentType = res.headers.get("content-type") ?? "";
    if (!res.ok || !res.body || !contentType.startsWith("image/")) return null;
    if (Number(res.headers.get("content-length") ?? 0) > MAX_BYTES) return null;

    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of res.body) {
      size += chunk.length;
      if (size > MAX_BYTES) return null;
      chunks.push(Buffer.from(chunk));
    }

    const id = randomUUID();
    images.set(id, { body: Buffer.concat(chunks), contentType });
    while (images.size > KEEP) images.delete(images.keys().next().value!);
    return id;
  } catch (err) {
    console.warn(`Couldn't fetch photo ${url}: ${err instanceof Error ? err.message : err}`);
    return null;
  }
}

export function getImage(id: string): CachedImage | undefined {
  return images.get(id);
}
