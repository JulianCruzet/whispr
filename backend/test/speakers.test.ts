// Tests for telling the wearer from the other person by voice. The "voices" are
// synthesised (a pulse train at the speaker's pitch through vocal-tract resonances,
// the textbook source-filter model of speech), all at the same loudness, so only
// what the voice sounds like can tell them apart.
//
//   cd backend && npm test

import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { SpeakerModel, splitBySpeaker, type TimedWord } from "../src/ears/speakers.js";
import { voiceprint } from "../src/ears/voiceprint.js";

const SAMPLE_RATE = 16000;

interface Voice {
  /** Pitch in Hz. */
  f0: number;
  /** Vocal tract length: >1 means a shorter tract (higher resonances). */
  tract: number;
}

const ALEX: Voice = { f0: 112, tract: 1.0 }; // the wearer
const SAM: Voice = { f0: 128, tract: 1.14 }; // similar pitch, different voice
const KIM: Voice = { f0: 205, tract: 1.2 };

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
function speak(voice: Voice, seconds: number, seed: number, targetDb = -24): Buffer {
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

function calibrated(me: Voice, them: Voice): SpeakerModel {
  const model = new SpeakerModel();
  assert.ok(model.calibrate("me", voiceprint(speak(me, 3, 1)), -24));
  assert.ok(model.calibrate("them", voiceprint(speak(them, 3, 2)), -24));
  return model;
}

describe("voiceprint", () => {
  test("silence has no voiceprint; speech has one with its length", () => {
    assert.equal(voiceprint(Buffer.alloc(SAMPLE_RATE * 2 * 2)), null);
    const print = voiceprint(speak(ALEX, 2, 3));
    assert.ok(print);
    assert.ok(print.seconds > 1 && print.seconds <= 2, `seconds ${print.seconds}`);
    assert.equal(print.mean.length, 14);
  });

  test("pitch comes out near the speaker's real pitch", () => {
    const semitones = voiceprint(speak(KIM, 2, 4))!.mean[12];
    const hz = 100 * 2 ** (semitones / 12);
    assert.ok(Math.abs(hz - KIM.f0) < 15, `pitch ${hz.toFixed(0)} Hz`);
  });
});

describe("telling two voices apart at the same loudness", () => {
  for (const [name, other] of [
    ["similar pitch, different voice", SAM],
    ["higher voice", KIM],
  ] as const) {
    test(`wearer vs ${name}: every new line lands on the right side`, () => {
      const model = calibrated(ALEX, other);
      for (let seed = 10; seed < 16; seed++) {
        assert.equal(model.classify(voiceprint(speak(ALEX, 2.5, seed)), -24).speaker, "me", `wearer line ${seed}`);
        assert.equal(model.classify(voiceprint(speak(other, 2.5, seed + 50)), -24).speaker, "them", `their line ${seed}`);
      }
    });
  }

  test("loudness doesn't fool it: a loud line from them is still them", () => {
    const model = calibrated(ALEX, SAM);
    assert.equal(model.classify(voiceprint(speak(SAM, 2.5, 30, -12)), -12).speaker, "them");
    assert.equal(model.classify(voiceprint(speak(ALEX, 2.5, 31, -36)), -36).speaker, "me");
  });

  test("a voice it has never heard isn't forced onto either side with confidence", () => {
    const model = calibrated(ALEX, KIM);
    const verdict = model.classify(voiceprint(speak({ f0: 160, tract: 1.1 }, 2.5, 40)), -24, { learn: false });
    assert.ok(verdict.position! > 0.15 && verdict.position! < 0.85, `position ${verdict.position}`);
  });
});

describe("fallbacks", () => {
  test("not calibrated: unknown, so the brain decides from the words", () => {
    assert.equal(new SpeakerModel().classify(voiceprint(speak(ALEX, 2, 5)), -24).speaker, "unknown");
  });

  test("only the wearer calibrated: falls back to loudness", () => {
    const model = new SpeakerModel();
    model.calibrate("me", voiceprint(speak(ALEX, 3, 6, -22)), -22);
    assert.equal(model.classify(null, -24).speaker, "me");
    assert.equal(model.classify(null, -33).speaker, "them");
  });

  test("a calibration line with too little speech is rejected for the other person", () => {
    const model = new SpeakerModel();
    assert.equal(model.calibrate("them", voiceprint(speak(SAM, 0.3, 7)), -24), false);
    assert.equal(model.calibrated.them, false);
  });
});

describe("splitting a line that holds both voices", () => {
  const words = (from: number, to: number, label: string): TimedWord[] =>
    Array.from({ length: Math.round((to - from) / 0.4) }, (_, i) => ({
      text: `${label}${i}`,
      start: from + i * 0.4,
      end: from + i * 0.4 + 0.35,
    }));

  test("wearer then them in one commit comes back as two turns", () => {
    const model = calibrated(ALEX, KIM);
    const audio = Buffer.concat([speak(ALEX, 2.4, 60), speak(KIM, 2.4, 61)]);
    const printOf = (from: number, to: number) =>
      voiceprint(audio.subarray(Math.floor(from * SAMPLE_RATE) * 2, Math.floor(to * SAMPLE_RATE) * 2));

    const parts = splitBySpeaker([...words(0, 2.4, "me"), ...words(2.4, 4.8, "them")], printOf, model);
    assert.ok(parts, "expected a split");
    assert.deepEqual(
      parts.map((p) => p.speaker),
      ["me", "them"],
    );
    assert.ok(parts[0].text.startsWith("me0") && parts[1].text.includes("them"));
  });

  test("one voice throughout stays one turn", () => {
    const model = calibrated(ALEX, KIM);
    const audio = speak(ALEX, 4.8, 62);
    const printOf = (from: number, to: number) =>
      voiceprint(audio.subarray(Math.floor(from * SAMPLE_RATE) * 2, Math.floor(to * SAMPLE_RATE) * 2));
    assert.equal(splitBySpeaker(words(0, 4.8, "w"), printOf, model), null);
  });
});
