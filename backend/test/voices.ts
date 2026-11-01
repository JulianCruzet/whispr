// Synthesised voices for tests: a pulse train at the speaker's pitch through vocal-tract
// resonances (the textbook source-filter model of speech), at a chosen loudness. Runs on
// any OS, so tests don't need recordings.

export const SAMPLE_RATE = 16000;

export interface Voice {
  /** Pitch in Hz. */
  f0: number;
  /** Vocal tract length: >1 means a shorter tract (higher resonances). */
  tract: number;
}

export const ALEX: Voice = { f0: 112, tract: 1.0 }; // the wearer
export const SAM: Voice = { f0: 128, tract: 1.14 }; // similar pitch, different voice
export const KIM: Voice = { f0: 205, tract: 1.2 };

// Formants (Hz) of a few vowels for an average adult tract.
const VOWELS = [
  [730, 1090, 2440],
  [270, 2290, 3010],
  [300, 870, 2240],
  [530, 1840, 2480],
  [570, 840, 2410],
  [440, 1020, 2240],
];

/** `seconds` of speech-like audio in `voice`: syllables of shifting vowels with short pauses. */
export function speak(voice: Voice, seconds: number, seed: number, targetDb = -24): Buffer {
  let state = seed * 7919 + 13;
  const random = () => ((state = (state * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  const n = Math.floor(seconds * SAMPLE_RATE);
  const out = new Float64Array(n);
  const syllable = Math.floor(0.19 * SAMPLE_RATE);
  const filters = [0, 1, 2].map(() => ({ y1: 0, y2: 0 }));
  let phase = 0;
  let vowel = VOWELS[0];

  for (let i = 0; i < n; i++) {
    const inSyllable = i % syllable;
    if (inSyllable === 0) vowel = VOWELS[Math.floor(random() * VOWELS.length)];
    const pause = Math.floor(i / syllable) % 5 === 4; // every fifth syllable is a gap
    const envelope = pause ? 0 : Math.sin((Math.PI * inSyllable) / syllable);

    // Glottal source: a pulse each pitch period, with a little natural wobble.
    const pitch = voice.f0 * (1 + 0.03 * Math.sin((2 * Math.PI * i) / (SAMPLE_RATE * 0.37)) + 0.01 * (random() - 0.5));
    phase += pitch / SAMPLE_RATE;
    let x = 0;
    if (phase >= 1) {
      phase -= 1;
      x = 1;
    }
    x = x * envelope + 0.002 * (random() - 0.5);

    // Vocal tract: three resonators in series.
    vowel.forEach((formant, k) => {
      const f = formant * voice.tract;
      const bandwidth = 80 + 40 * k;
      const r = Math.exp((-Math.PI * bandwidth) / SAMPLE_RATE);
      const theta = (2 * Math.PI * f) / SAMPLE_RATE;
      const filter = filters[k];
      const y = (1 - r) * x + 2 * r * Math.cos(theta) * filter.y1 - r * r * filter.y2;
      filter.y2 = filter.y1;
      filter.y1 = y;
      x = y;
    });
    out[i] = x;
  }

  const rms = Math.sqrt(out.reduce((s, v) => s + v * v, 0) / n);
  const gain = 10 ** (targetDb / 20) / (rms || 1);
  const pcm = Buffer.alloc(n * 2);
  for (let i = 0; i < n; i++) {
    const noise = 10 ** (-55 / 20) * (random() - 0.5) * 2;
    pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round((out[i] * gain + noise) * 32767))), i * 2);
  }
  return pcm;
}

