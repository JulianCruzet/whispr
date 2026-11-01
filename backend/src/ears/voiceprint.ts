// EARS: what a voice sounds like, so the wearer can be told apart from the person
// across from them even when both are equally loud in the mic.
//
// A voiceprint is the average timbre of a stretch of speech (12 MFCCs, the standard
// speech features), its median pitch, and its loudness, plus how much each of those
// varies frame to frame. speakers.ts compares voiceprints against short samples of
// each speaker taken during calibration.

const SAMPLE_RATE = 16000;
const FRAME = 400; // 25 ms
const HOP = 160; // 10 ms
const NFFT = 512;
const MEL_BANDS = 26;
const CEPSTRA = 12; // c1..c12; c0 (overall energy) is left out on purpose
const MIN_HZ = 80;
const MAX_HZ = 7600;

const PITCH_WINDOW = 640; // 40 ms
const PITCH_MIN_LAG = Math.floor(SAMPLE_RATE / 400); // 400 Hz
const PITCH_MAX_LAG = Math.ceil(SAMPLE_RATE / 70); // 70 Hz
const PITCH_MIN_CLARITY = 0.5;

/** Frames quieter than this, this far below the loudest frame, or this close to the room's
 *  noise floor are pauses or background, not speech. */
const SILENCE_DB = -55;
const SPEECH_RANGE_DB = 30;
const ABOVE_NOISE_DB = 10;

export interface Voiceprint {
  /** Feature means: 12 MFCCs, then pitch (semitones above 100 Hz, or NaN if unvoiced), then loudness (dB). */
  mean: number[];
  /** Frame-to-frame variance of each feature, same order as `mean`. */
  variance: number[];
  /** Seconds of speech the voiceprint was taken from (pauses excluded). */
  seconds: number;
}

export const FEATURES = CEPSTRA + 2;
export const PITCH = CEPSTRA;
export const LEVEL = CEPSTRA + 1;

/** Voiceprint of PCM16 mono 16 kHz audio, or null if there isn't enough speech in it. */
export function voiceprint(pcm: Buffer): Voiceprint | null {
  const samples = toFloat(pcm);
  if (samples.length < FRAME * 4) return null;

  // Find the speech frames first, by loudness.
  const frameCount = Math.floor((samples.length - FRAME) / HOP) + 1;
  const frameDb = new Float64Array(frameCount);
  for (let f = 0; f < frameCount; f++) frameDb[f] = rmsDb(samples, f * HOP, FRAME);
  const loudest = Math.max(...frameDb);
  // The quietest tenth of frames is the room between words: the noise floor.
  const noiseFloor = [...frameDb].sort((a, b) => a - b)[Math.floor(frameCount * 0.1)];
  const threshold = Math.max(SILENCE_DB, loudest - SPEECH_RANGE_DB, noiseFloor + ABOVE_NOISE_DB);
  const speech: number[] = [];
  for (let f = 0; f < frameCount; f++) {
    if (frameDb[f] > threshold) speech.push(f);
  }
  if (speech.length < 20) return null; // under ~0.2 s of speech

  const cepstra = speech.map((f) => mfcc(samples, f * HOP));
  const pitches = speech
    .filter((_, i) => i % 2 === 0)
    .map((f) => pitchHz(samples, f * HOP))
    .filter((hz): hz is number => hz !== null)
    .map((hz) => 12 * Math.log2(hz / 100));
  const levels = speech.map((f) => frameDb[f]);

  const mean: number[] = [];
  const variance: number[] = [];
  for (let c = 0; c < CEPSTRA; c++) {
    const column = cepstra.map((row) => row[c]);
    mean.push(average(column));
    variance.push(spread(column));
  }
  // Pitch only counts if enough frames were clearly voiced.
  if (pitches.length >= 5) {
    mean.push(median(pitches));
    variance.push(spread(pitches));
  } else {
    mean.push(NaN);
    variance.push(NaN);
  }
  mean.push(average(levels));
  variance.push(spread(levels));

  return { mean, variance, seconds: (speech.length * HOP) / SAMPLE_RATE };
}

// MARK: Features

const window = Float64Array.from({ length: FRAME }, (_, i) => 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (FRAME - 1)));
const melFilters = buildMelFilters();
const dct = Array.from({ length: CEPSTRA }, (_, k) =>
  Float64Array.from({ length: MEL_BANDS }, (_, m) => Math.cos((Math.PI * (k + 1) * (m + 0.5)) / MEL_BANDS)),
);

function mfcc(samples: Float32Array, start: number): number[] {
  const re = new Float64Array(NFFT);
  const im = new Float64Array(NFFT);
  for (let i = 0; i < FRAME; i++) {
    const preEmphasised = samples[start + i] - 0.97 * (start + i > 0 ? samples[start + i - 1] : 0);
    re[i] = preEmphasised * window[i];
  }
  fft(re, im);

  const bins = NFFT / 2 + 1;
  const power = new Float64Array(bins);
  for (let b = 0; b < bins; b++) power[b] = (re[b] * re[b] + im[b] * im[b]) / NFFT;

  const logMel = new Float64Array(MEL_BANDS);
  for (let m = 0; m < MEL_BANDS; m++) {
    let energy = 0;
    const filter = melFilters[m];
    for (let b = 0; b < bins; b++) energy += filter[b] * power[b];
    logMel[m] = Math.log(energy + 1e-10);
  }

  return dct.map((row) => row.reduce((sum, weight, m) => sum + weight * logMel[m], 0));
}

/** Pitch of one 40 ms window by normalized autocorrelation, or null if it isn't clearly voiced. */
function pitchHz(samples: Float32Array, start: number): number | null {
  if (start + PITCH_WINDOW + PITCH_MAX_LAG > samples.length) return null;
  let bestLag = 0;
  let bestClarity = 0;
  for (let lag = PITCH_MIN_LAG; lag <= PITCH_MAX_LAG; lag++) {
    let cross = 0;
    let energyA = 0;
    let energyB = 0;
    for (let i = 0; i < PITCH_WINDOW; i++) {
      const a = samples[start + i];
      const b = samples[start + i + lag];
      cross += a * b;
      energyA += a * a;
      energyB += b * b;
    }
    const clarity = cross / Math.sqrt(energyA * energyB + 1e-12);
    if (clarity > bestClarity) {
      bestClarity = clarity;
      bestLag = lag;
    }
  }
  return bestClarity >= PITCH_MIN_CLARITY ? SAMPLE_RATE / bestLag : null;
}

function buildMelFilters(): Float64Array[] {
  const toMel = (hz: number) => 2595 * Math.log10(1 + hz / 700);
  const toHz = (mel: number) => 700 * (10 ** (mel / 2595) - 1);
  const bins = NFFT / 2 + 1;
  const low = toMel(MIN_HZ);
  const high = toMel(MAX_HZ);
  const edges = Array.from({ length: MEL_BANDS + 2 }, (_, i) =>
    Math.floor(((NFFT + 1) * toHz(low + ((high - low) * i) / (MEL_BANDS + 1))) / SAMPLE_RATE),
  );
  return Array.from({ length: MEL_BANDS }, (_, m) => {
    const filter = new Float64Array(bins);
    const [left, centre, right] = [edges[m], edges[m + 1], edges[m + 2]];
    for (let b = left; b < centre; b++) filter[b] = (b - left) / Math.max(1, centre - left);
    for (let b = centre; b < right; b++) filter[b] = (right - b) / Math.max(1, right - centre);
    return filter;
  });
}

/** In-place iterative radix-2 FFT. */
function fft(re: Float64Array, im: Float64Array) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let size = 2; size <= n; size <<= 1) {
    const angle = (-2 * Math.PI) / size;
    for (let start = 0; start < n; start += size) {
      for (let k = 0; k < size / 2; k++) {
        const cos = Math.cos(angle * k);
        const sin = Math.sin(angle * k);
        const a = start + k;
        const b = a + size / 2;
        const tre = re[b] * cos - im[b] * sin;
        const tim = re[b] * sin + im[b] * cos;
        re[b] = re[a] - tre;
        im[b] = im[a] - tim;
        re[a] += tre;
        im[a] += tim;
      }
    }
  }
}

// MARK: Helpers

function toFloat(pcm: Buffer): Float32Array {
  const out = new Float32Array(Math.floor(pcm.length / 2));
  for (let i = 0; i < out.length; i++) out[i] = pcm.readInt16LE(i * 2) / 32768;
  return out;
}

function rmsDb(samples: Float32Array, start: number, length: number): number {
  let sum = 0;
  for (let i = start; i < start + length; i++) sum += samples[i] * samples[i];
  return Math.max(-90, 10 * Math.log10(sum / length + 1e-12));
}

const average = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

function spread(xs: number[]): number {
  const m = average(xs);
  return xs.reduce((sum, x) => sum + (x - m) ** 2, 0) / xs.length;
}

function median(xs: number[]): number {
  const sorted = [...xs].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}
