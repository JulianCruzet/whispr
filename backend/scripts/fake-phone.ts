// Pretends to be the iPhone: connects to /ws, optionally streams a WAV file as
// mic audio, sends a typed line, and reports what comes back.
//
//   npx tsx scripts/fake-phone.ts "wait, you saw Laufey live?"
//   npx tsx scripts/fake-phone.ts --wav sample-16k-mono.wav
//   npx tsx scripts/fake-phone.ts --calibrate --wav conversation.wav   (first line spoken = you)
//   npx tsx scripts/fake-phone.ts --calibrate-both --wav conversation.wav   (first line = you, second = them)
//
// Env: WHISPR_URL (default ws://localhost:8787/ws)

import { readFileSync } from "node:fs";
import WebSocket from "ws";

const url = process.env.WHISPR_URL ?? "ws://localhost:8787/ws";
const rawArgs = process.argv.slice(2);
const calibrateBoth = rawArgs.includes("--calibrate-both");
const calibrate = calibrateBoth || rawArgs.includes("--calibrate");
const args = rawArgs.filter((a) => a !== "--calibrate" && a !== "--calibrate-both");
const wavIndex = args.indexOf("--wav");
const wavPath = wavIndex >= 0 ? args[wavIndex + 1] : null;
const line = (wavIndex >= 0 ? args.filter((_, i) => i !== wavIndex && i !== wavIndex + 1) : args).join(" ");

const ws = new WebSocket(url);
let audioBytes = 0;
const started = Date.now();
const ms = () => `${String(Date.now() - started).padStart(5)}ms`;

ws.on("open", async () => {
  ws.send(JSON.stringify({ type: "hello", device: "fake-phone", sampleRate: 16000 }));
  if (calibrate) ws.send(JSON.stringify({ type: "calibrate" }));
  if (line) ws.send(JSON.stringify({ type: "debug_turn", text: line, speaker: "them" }));
  if (wavPath) {
    // Assumes a 16 kHz mono PCM16 WAV with a 44-byte header.
    const pcm = readFileSync(wavPath).subarray(44);
    for (let i = 0; i < pcm.length; i += 3200) {
      ws.send(pcm.subarray(i, i + 3200), { binary: true });
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  setTimeout(() => ws.close(), 8000);
});

ws.on("message", (data, isBinary) => {
  if (isBinary) {
    audioBytes += (data as Buffer).length;
    return;
  }
  const event = JSON.parse(data.toString());
  // After the wearer's sample, the next line is the other person's.
  if (calibrateBoth && event.type === "calibrated" && event.who === "me") {
    ws.send(JSON.stringify({ type: "calibrate", who: "them" }));
  }
  if (event.type === "whisper_audio_end") {
    console.log(`${ms()} whisper_audio_end (${audioBytes} bytes of audio)`);
    audioBytes = 0;
  } else {
    console.log(`${ms()} ${JSON.stringify(event)}`);
  }
});

ws.on("close", () => process.exit(0));
ws.on("error", (err) => {
  console.error(err.message);
  process.exit(1);
});
