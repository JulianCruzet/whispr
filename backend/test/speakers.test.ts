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
import { ALEX, KIM, SAM, SAMPLE_RATE, speak, type Voice } from "./voices.js";

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

  test("only the wearer calibrated: a full line is judged by how far it is from their voice", () => {
    const model = new SpeakerModel();
    model.calibrate("me", voiceprint(speak(ALEX, 5.6, 6)), -24);
    // Same loudness throughout, so only the voice can tell them apart.
    // Clip lengths 0.6 to 2.4 s, so short ones (under 1 s of speech) are covered too.
    const heard = (voice: Voice) =>
      Array.from({ length: 24 }, (_, i) => model.classify(voiceprint(speak(voice, 0.6 + (i % 4) * 0.6, 40 + i)), -24).speaker);
    const wearer = heard(ALEX);
    assert.ok(!wearer.includes("them"), "the wearer is never mistaken for the other person");
    assert.ok(wearer.filter((s) => s === "me").length >= 6, `wearer: ${wearer}`);
    assert.ok(heard(KIM).every((s) => s === "them"), "a clearly different voice is them");
    assert.ok(!heard(SAM).includes("me"), "a similar voice is never taken for the wearer");
  });

  test("only the wearer calibrated, and a line without a voiceprint: falls back to loudness", () => {
    const model = new SpeakerModel();
    model.calibrate("me", voiceprint(speak(ALEX, 3, 6, -22)), -22);
    assert.equal(model.classify(null, -24).speaker, "me");
    assert.equal(model.classify(null, -33).speaker, "them");
  });

  test("both calibrated but no voiceprint: unknown, not a loudness guess", () => {
    const model = calibrated(ALEX, KIM);
    assert.equal(model.classify(null, -20).speaker, "unknown");
  });

  test("a line cut to its words keeps its quieter speech when the room's noise level is known", () => {
    // No pauses at all, alternating louder and quieter stretches, like speech cut tight to
    // its words: on its own, its quietest frames look like the noise floor.
    let seed = 7;
    const random = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) - 0.5;
    const pcm = Buffer.alloc(3 * SAMPLE_RATE * 2);
    for (let i = 0; i < pcm.length / 2; i++) {
      const louder = Math.floor(i / 1600) % 2 === 0; // 100 ms stretches
      pcm.writeInt16LE(Math.round(random() * (louder ? 4000 : 1500)), i * 2);
    }
    const alone = voiceprint(pcm)?.seconds ?? 0;
    const withRoom = voiceprint(pcm, -70)?.seconds ?? 0;
    assert.ok(withRoom > 2.5, `with the room's level: ${withRoom}s of 3s`);
    assert.ok(alone < 2, `alone: ${alone}s`);
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

  test("a quick 'yeah' and then a long answer from the other person is split too", () => {
    const model = calibrated(ALEX, SAM);
    const audio = Buffer.concat([speak(ALEX, 1, 63), speak(SAM, 3, 64)]);
    const printOf = (from: number, to: number) =>
      voiceprint(audio.subarray(Math.floor(from * SAMPLE_RATE) * 2, Math.floor(to * SAMPLE_RATE) * 2));
    const timed = (from: number, to: number, label: string): TimedWord[] =>
      Array.from({ length: Math.floor((to - from) / 0.4) }, (_, i) => ({
        text: `${label}${i}`,
        start: from + i * 0.4,
        end: Math.min(to, from + i * 0.4 + 0.35),
      }));

    const parts = splitBySpeaker([...timed(0, 1, "me"), ...timed(1, 4, "them")], printOf, model);
    assert.deepEqual(parts?.map((p) => p.speaker), ["me", "them"]);
    assert.ok(!parts![1].text.includes("me"));
  });

  test("one voice throughout stays one turn", () => {
    const model = calibrated(ALEX, KIM);
    const audio = speak(ALEX, 4.8, 62);
    const printOf = (from: number, to: number) =>
      voiceprint(audio.subarray(Math.floor(from * SAMPLE_RATE) * 2, Math.floor(to * SAMPLE_RATE) * 2));
    assert.equal(splitBySpeaker(words(0, 4.8, "w"), printOf, model), null);
  });
});
