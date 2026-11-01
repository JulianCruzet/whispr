// TASKS (owner: Person B)
// Finds a "proof" photo for the user's claim. Falls back to a known-good photo
// if search is unconfigured, fails, or is slow, so the demo never comes up empty.

import { config } from "../config.js";

export interface PhotoResult {
  imageUrl: string | null;
  caption: string;
}

const SEARCH_TIMEOUT_MS = 5000;

export async function findPhoto(query: string): Promise<PhotoResult> {
  const fallback: PhotoResult = { imageUrl: config.tasks.fallbackPhotoUrl || null, caption: query };
  if (!config.tasks.serpApiKey) return fallback;

  try {
    const url = new URL("https://serpapi.com/search.json");
    url.searchParams.set("engine", "google_images");
    url.searchParams.set("q", query);
    url.searchParams.set("api_key", config.tasks.serpApiKey);

    const res = await fetch(url, { signal: AbortSignal.timeout(SEARCH_TIMEOUT_MS) });
    if (!res.ok) return fallback;
    const data = (await res.json()) as { images_results?: { original?: string; title?: string }[] };
    const top = data.images_results?.find((r) => r.original);
    return top?.original ? { imageUrl: top.original, caption: top.title ?? query } : fallback;
  } catch {
    return fallback;
  }
}
