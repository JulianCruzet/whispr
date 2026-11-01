// EARS: who said a line. Scribe realtime doesn't label speakers, so this compares each
// line's voiceprint with short samples of both voices taken during calibration.
// When it can't tell, it says "unknown" and the brain (Jev) decides from the words.

import type { Speaker } from "../protocol.js";
import { FEATURES, LEVEL, type Voiceprint } from "./voiceprint.js";

export type Who = "me" | "them";

export interface Verdict {
  speaker: Speaker;
  /** Where the line sits between the two voices: 0 sounds like the wearer, 1 like the other person. */
  position: number | null;
  how: "voice" | "loudness" | "none";
}

/** How far from the midpoint (0.5) a line must land to count as one voice or the other. */
const MARGIN = 0.12;
/** Short clips have noisy voiceprints, so they need more margin. */
const SHORT_CLIP_SECONDS = 1;
const SHORT_CLIP_MARGIN = 0.22;
/** Confident lines nudge that voice's sample, to follow the mic moving or a voice warming up. */
const ADAPT_RATE = 0.15;
const ADAPT_MIN_SECONDS = 1.2;
const ADAPT_MIN_DISTANCE = 0.3;
/** A line with no voiceprint falls back to loudness: this much quieter than the wearer is "them". */
const LOUDNESS_MARGIN_DB = 8;
/**
 * How far a line is from one voice's sample (see `distance`). Measured on recorded voices
 * at equal loudness: a voice against its own sample scores 0.20-0.45, a different voice
 * 0.49 and up (median 1.26). The synthetic test voices wobble more: against a 4 s sample,
 * the wearer's own lines reach 0.86 and a similar voice starts at 0.68.
 */
/** At or under this, it's that voice. */
const SAME_VOICE = 0.45;
/**
 * At or over this, it's someone else. Set high because calling the wearer "them" whispers
 * a reply to their own line; between this and SAME_VOICE is "unknown", so Jev decides.
 */
const OTHER_VOICE = 1.0;
/** Under this, a line might still be that voice. */
const MAYBE_SAME_VOICE = 0.85;
/** Clips under SHORT_CLIP_SECONDS wobble more (the wearer's reach 1.11), so need clearer scores. */
const SHORT_CLIP_SAME_VOICE = 0.35;
const SHORT_CLIP_OTHER_VOICE = 1.4;
/** A calibration sample needs at least this much speech to be useful as a voiceprint. */
const MIN_SAMPLE_SECONDS = 0.8;

export class SpeakerModel {
  private samples: Record<Who, Voiceprint | null> = { me: null, them: null };
  private myLevelDb: number | null = null;

  get calibrated(): Record<Who, boolean> {
    return { me: this.samples.me !== null || this.myLevelDb !== null, them: this.samples.them !== null };
  }

  /** Learns one voice from a line known to be theirs. Returns false if the line was unusable. */
  calibrate(who: Who, print: Voiceprint | null, levelDb: number | null): boolean {
    const usable = print !== null && print.seconds >= MIN_SAMPLE_SECONDS;
    if (print && usable) this.samples[who] = { ...print, mean: [...print.mean], variance: [...print.variance] };
    // The loudness fallback compares like with like: the line's level as the gateway measures it.
    if (who === "me") {
      const level = levelDb ?? (print && usable ? print.mean[LEVEL] : null);
      if (level !== null) this.myLevelDb = level;
    }
    return usable || (who === "me" && levelDb !== null);
  }

  /** Who said a line, from its voiceprint (preferred) or its loudness. */
  classify(print: Voiceprint | null, levelDb: number | null, { learn = true } = {}): Verdict {
    const { me, them } = this.samples;
    if (me && them && print) {
      const position = this.position(print);
      if (position !== null) {
        const margin = print.seconds < SHORT_CLIP_SECONDS ? SHORT_CLIP_MARGIN : MARGIN;
        const speaker: Speaker = position <= 0.5 - margin ? "me" : position >= 0.5 + margin ? "them" : "unknown";
        if (learn && speaker !== "unknown" && print.seconds >= ADAPT_MIN_SECONDS && Math.abs(position - 0.5) >= ADAPT_MIN_DISTANCE) {
          this.adapt(speaker, print);
        }
        return { speaker, position, how: "voice" };
      }
    }

    // Only the wearer's sample: does this sound like them?
    if (me && !them && print) {
      const d = distance(print, me);
      const short = print.seconds < SHORT_CLIP_SECONDS;
      const speaker: Speaker =
        d <= (short ? SHORT_CLIP_SAME_VOICE : SAME_VOICE)
          ? "me"
          : d >= (short ? SHORT_CLIP_OTHER_VOICE : OTHER_VOICE)
            ? "them"
            : "unknown";
      return { speaker, position: null, how: "voice" };
    }

    const level = levelDb ?? print?.mean[LEVEL] ?? null;
    if (this.myLevelDb !== null && level !== null) {
      return {
        speaker: level >= this.myLevelDb - LOUDNESS_MARGIN_DB ? "me" : "them",
        position: null,
        how: "loudness",
      };
    }
    return { speaker: "unknown", position: null, how: "none" };
  }

  /** True if `print` sounds like `who`'s sample (false if there's no sample of `who`). */
  soundsLike(who: Who, print: Voiceprint): boolean {
    const sample = this.samples[who];
    return sample !== null && distance(print, sample) <= SAME_VOICE;
  }

  /** True unless `print` is clearly someone other than `who` (false if there's no sample of `who`). */
  couldBe(who: Who, print: Voiceprint): boolean {
    const sample = this.samples[who];
    return sample !== null && distance(print, sample) < MAYBE_SAME_VOICE;
  }

  /**
   * A linear discriminant between the two samples: each feature counts by how much it
   * separates the two voices relative to how much it wobbles within one voice. 0 lands on
   * the wearer's sample, 1 on the other person's.
   */
  private position(print: Voiceprint): number | null {
    const { me, them } = this.samples;
    if (!me || !them) return null;
    let along = 0;
    let length = 0;
    for (let i = 0; i < FEATURES; i++) {
      const a = me.mean[i];
      const b = them.mean[i];
      const x = print.mean[i];
      if (!Number.isFinite(a) || !Number.isFinite(b) || !Number.isFinite(x)) continue;
      const wobble = (me.variance[i] + them.variance[i]) / 2 + 1e-6;
      const gap = b - a;
      along += ((x - a) * gap) / wobble;
      length += (gap * gap) / wobble;
    }
    return length > 1e-9 ? along / length : null;
  }

  private adapt(who: Who, print: Voiceprint) {
    const sample = this.samples[who as Who];
    if (!sample) return;
    for (let i = 0; i < FEATURES; i++) {
      if (Number.isFinite(sample.mean[i]) && Number.isFinite(print.mean[i])) {
        sample.mean[i] += ADAPT_RATE * (print.mean[i] - sample.mean[i]);
      }
    }
  }
}

export interface TimedWord {
  text: string;
  start: number;
  end: number;
}

/** Words are classified in runs of at least this long; a speaker change needs this much on each side. */
const SPLIT_CHUNK_SECONDS = 1;
const SPLIT_MIN_RUN_SECONDS = 0.8;

/**
 * Scribe sometimes commits a quick back-and-forth as one line. When both voices are
 * calibrated, this classifies the line in ~1 s pieces and, if it clearly switches
 * speaker, returns it split at the word where the switch happens. Otherwise null.
 */
export function splitBySpeaker(
  words: TimedWord[],
  printOf: (from: number, to: number) => Voiceprint | null,
  model: SpeakerModel,
): { text: string; speaker: Who }[] | null {
  if (!model.calibrated.me || !model.calibrated.them || words.length < 2) return null;
  if (words[words.length - 1].end - words[0].start < 2 * SPLIT_MIN_RUN_SECONDS) return null;

  // Group words into ~1 s chunks and label each one.
  const chunks: { words: TimedWord[]; speaker: Speaker }[] = [];
  let current: TimedWord[] = [];
  for (const word of words) {
    current.push(word);
    if (word.end - current[0].start >= SPLIT_CHUNK_SECONDS) {
      chunks.push({ words: current, speaker: "unknown" });
      current = [];
    }
  }
  if (current.length) chunks.push({ words: current, speaker: "unknown" });
  for (const chunk of chunks) {
    const from = chunk.words[0].start;
    const to = chunk.words[chunk.words.length - 1].end;
    chunk.speaker = model.classify(printOf(from, to), null, { learn: false }).speaker;
  }

  // Merge neighbours with the same label; an unsure chunk joins the run before it.
  const runs: { words: TimedWord[]; speaker: Speaker }[] = [];
  for (const chunk of chunks) {
    const last = runs[runs.length - 1];
    if (last && (chunk.speaker === last.speaker || chunk.speaker === "unknown")) last.words.push(...chunk.words);
    else runs.push({ words: [...chunk.words], speaker: chunk.speaker });
  }
  if (runs.length > 1 && runs[0].speaker === "unknown") {
    runs[1].words.unshift(...runs[0].words);
    runs.shift();
  }

  const confident = runs.every(
    (run) => run.speaker !== "unknown" && run.words[run.words.length - 1].end - run.words[0].start >= SPLIT_MIN_RUN_SECONDS,
  );
  if (runs.length < 2 || !confident) return null;
  return runs.map((run) => ({ text: run.words.map((w) => w.text).join(" "), speaker: run.speaker as Who }));
}

/**
 * How far a voiceprint is from a sample, in units of the sample's own frame-to-frame
 * wobble (root mean square over the timbre and pitch features; loudness is left out
 * because people move and change volume).
 */
export function distance(print: Voiceprint, sample: Voiceprint): number {
  let sum = 0;
  let count = 0;
  for (let i = 0; i < LEVEL; i++) {
    const a = sample.mean[i];
    const x = print.mean[i];
    const wobble = sample.variance[i];
    if (!Number.isFinite(a) || !Number.isFinite(x) || !Number.isFinite(wobble)) continue;
    sum += (x - a) ** 2 / (wobble + 1e-6);
    count++;
  }
  return count ? Math.sqrt(sum / count) : Infinity;
}

