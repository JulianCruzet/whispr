// Measures how well the voiceprint tells two voices apart, with loudness equalised
// (so it can't cheat on volume) and some room noise. macOS: record clips with `say`
// into a folder as <Voice>-<n>.wav (16 kHz mono), then:
//
//   npx tsx scripts/eval-speakers.ts /tmp/voices Daniel Samantha
//
// Sentence 0 of each voice is the calibration sample; the rest are classified.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { SpeakerModel } from "../src/ears/speakers.js";
import { voiceprint } from "../src/ears/voiceprint.js";

const [dir, meVoice, themVoice, noiseArg] = process.argv.slice(2);
const TARGET_DB = -24;
const noiseDb = Number(noiseArg ?? -50);

/** PCM16 from a WAV, wherever its data chunk is, at TARGET_DB RMS plus white noise. */
function load(path: string, seed: number): Buffer {
  const wav = readFileSync(path);
  let offset = 12;
  while (wav.toString("ascii", offset, offset + 4) !== "data") offset += 8 + wav.readUInt32LE(offset + 4);
  const data = wav.subarray(offset + 8, offset + 8 + wav.readUInt32LE(offset + 4));
  const samples = Array.from({ length: data.length / 2 }, (_, i) => data.readInt16LE(i * 2) / 32768);
  const rms = Math.sqrt(samples.reduce((s, x) => s + x * x, 0) / samples.length);
  const gain = 10 ** (TARGET_DB / 20) / rms;
  const noise = 10 ** (noiseDb / 20) * Math.sqrt(3);
  let state = seed;
  const random = () => ((state = (state * 1103515245 + 12345) % 2 ** 31) / 2 ** 31) * 2 - 1;
  const out = Buffer.alloc(data.length);
  samples.forEach((x, i) => out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round((x * gain + random() * noise) * 32767))), i * 2));
  return out;
}

const clips = (voice: string) =>
  readdirSync(dir)
    .filter((f) => f.startsWith(`${voice}-`) && f.endsWith(".wav"))
    .sort()
    .map((f, i) => voiceprint(load(join(dir, f), i + voice.length))!);

const me = clips(meVoice);
const them = clips(themVoice);
const model = new SpeakerModel();
model.calibrate("me", me[0], null);
model.calibrate("them", them[0], null);

let right = 0;
let wrong = 0;
let unsure = 0;
const rows: string[] = [];
for (const [truth, prints] of [["me", me.slice(1)], ["them", them.slice(1)]] as const) {
  for (const print of prints) {
    const verdict = model.classify(print, null, { learn: false });
    if (verdict.speaker === "unknown") unsure++;
    else if (verdict.speaker === truth) right++;
    else wrong++;
    rows.push(`${truth.padEnd(4)} → ${verdict.speaker.padEnd(7)} position ${verdict.position?.toFixed(2)}`);
  }
}
console.log(rows.join("\n"));
console.log(`${meVoice} vs ${themVoice} (noise ${noiseDb} dB): right ${right}, wrong ${wrong}, unsure ${unsure} of ${right + wrong + unsure}`);
