// Tests for the audio gateway: loudness, me/them labels, the bridge to the brain,
// and whispers never overlapping. A fake brain and a fake phone socket stand in for
// the real ones, and ElevenLabs runs in mock mode (TTS plays a short chime).
//
//   cd backend && npm test

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { WebSocketServer, type WebSocket as ServerSocket } from "ws";
import { ALEX, KIM, speak } from "./voices.js";

// Must be set before the gateway's config loads (dotenv never overrides set variables).
process.env.ELEVENLABS_API_KEY = "";
process.env.APP_SHARED_TOKEN = "";

/** Stands in for the brain: records what it receives and replies with the given events. */
class FakeBrain {
  readonly received: Record<string, unknown>[] = [];
  reply: (msg: Record<string, unknown>) => Record<string, unknown>[] = () => [];
  private server!: WebSocketServer;
  private sockets = new Set<ServerSocket>();

  async start(): Promise<string> {
    this.server = new WebSocketServer({ port: 0 });
    this.server.on("connection", (ws) => {
      this.sockets.add(ws);
      ws.on("message", (data) => {
        const msg = JSON.parse(data.toString());
        this.received.push(msg);
        for (const event of this.reply(msg)) ws.send(JSON.stringify(event));
      });
    });
    await new Promise((resolve) => this.server.once("listening", resolve));
    return `ws://localhost:${(this.server.address() as AddressInfo).port}/ws`;
  }

  async stop() {
    for (const ws of this.sockets) ws.terminate();
    await new Promise((resolve) => this.server.close(resolve));
  }
}

/** Stands in for the phone's WebSocket as PhoneSession sees it. */
class FakePhone extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  /** JSON events and, as "<audio N bytes>", binary whisper audio, in order. */
  readonly log: (Record<string, any> | string)[] = [];

  send(data: string | Buffer, opts?: { binary?: boolean }) {
    this.log.push(opts?.binary ? `<audio ${(data as Buffer).length} bytes>` : JSON.parse(data as string));
  }

  say(msg: Record<string, unknown>) {
    this.emit("message", Buffer.from(JSON.stringify(msg)), false);
  }

  events(type: string) {
    return this.log.filter((e): e is Record<string, any> => typeof e !== "string" && e.type === type);
  }
}

async function until(check: () => boolean, ms = 3000) {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("timed out waiting");
    await new Promise((r) => setTimeout(r, 10));
  }
}

/** Stands in for an image host: /photo.jpg is an image (after ?delay= ms), anything else 404s. */
const PHOTO = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
let imageHost: Server;
let imageBase = "";

const brain = new FakeBrain();
let PhoneSession: typeof import("../src/session.js").PhoneSession;
let levelDb: typeof import("../src/ears/scribe.js").levelDb;
let getImage: typeof import("../src/media.js").getImage;

before(async () => {
  imageHost = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    if (url.pathname !== "/photo.jpg") return void res.writeHead(404).end();
    setTimeout(() => res.writeHead(200, { "Content-Type": "image/jpeg" }).end(PHOTO), Number(url.searchParams.get("delay") ?? 0));
  });
  await new Promise<void>((resolve) => imageHost.listen(0, resolve));
  imageBase = `http://localhost:${(imageHost.address() as AddressInfo).port}`;

  process.env.BRAIN_URL = await brain.start();
  ({ PhoneSession } = await import("../src/session.js"));
  ({ levelDb } = await import("../src/ears/scribe.js"));
  ({ getImage } = await import("../src/media.js"));
});

const phones: FakePhone[] = [];

after(async () => {
  // Hanging up closes each session's brain link, so nothing keeps the process alive.
  for (const phone of phones) phone.emit("close");
  await brain.stop();
  await new Promise((resolve) => imageHost.close(resolve));
});

function newSession() {
  const phone = new FakePhone();
  phones.push(phone);
  const session = new PhoneSession(phone as never);
  // Test hook: what Scribe would emit for a finished line at a given loudness.
  // Test hook: what Scribe would emit for a finished line at a given loudness (no audio, so
  // speaker detection falls back to loudness; speakers.test.ts covers voices).
  const scribeSays = (text: string, db: number | null) =>
    (session as any).scribe.emit("committed", text, { levelDb: db, words: [{ text, start: 0, end: 1 }] });
  return { phone, session, scribeSays };
}

describe("loudness", () => {
  test("silence is the floor and a full-scale tone is near 0 dBFS", () => {
    assert.equal(levelDb(Buffer.alloc(3200)), -90);
    const tone = Buffer.alloc(3200);
    for (let i = 0; i < 1600; i++) tone.writeInt16LE(Math.round(Math.sin(i / 3) * 32767), i * 2);
    assert.ok(Math.abs(levelDb(tone) - -3) < 0.5, `got ${levelDb(tone)}`);
  });
});

describe("me vs them", () => {
  test("before calibrating, lines are unknown and the brain gets no speaker", async () => {
    brain.received.length = 0;
    const { phone, scribeSays } = newSession();
    scribeSays("hello there", -20);
    await until(() => brain.received.length === 1);
    assert.equal(phone.events("transcript")[0].speaker, "unknown");
    assert.equal(brain.received[0].speaker, null);
    assert.equal(brain.received[0].is_final, true);
  });

});

describe("bridge to the brain", () => {
  test("the brain's who-spoke verdict relabels an unknown line, keeping its id", async () => {
    brain.reply = (msg) => [{ type: "transcript", text: msg.text, who_spoke: "them", cover_blown_risk: 0.4 }];
    const { phone, scribeSays } = newSession();
    scribeSays("wait, you saw her live?", -25);
    await until(() => phone.events("transcript").length === 2);

    const [first, relabel] = phone.events("transcript");
    assert.equal(first.speaker, "unknown");
    assert.equal(relabel.speaker, "them");
    assert.equal(relabel.id, first.id);
    assert.deepEqual(phone.events("risk")[0], { type: "risk", score: 0.4 });
  });

  test("a whisper is shown and spoken; photo tasks map to phone events", async () => {
    brain.reply = () => [
      { type: "whisper", id: "w1", text: "Say the Toronto show.", reason: "reply", cover_blown_risk: 0.2 },
      { type: "task_started", task_id: "t1", task: "find_photo" },
      {
        type: "task_done",
        task_id: "t1",
        task: "find_photo",
        ok: true,
        image_url: `${imageBase}/missing.jpg`,
        title: "Scotiabank Arena",
        query: "q",
        used_fallback: false,
      },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "which show?", speaker: "them" });
    await until(() => phone.events("whisper_audio_end").length === 1 && phone.events("task_done").length === 1);

    assert.deepEqual(phone.events("whisper")[0], { type: "whisper", id: "w1", text: "Say the Toronto show.", reason: "reply" });
    assert.equal(phone.events("task_started")[0].id, "t1");
    assert.deepEqual(phone.events("task_done")[0], {
      type: "task_done",
      id: "t1",
      kind: "find_photo",
      ok: true,
      // The relay couldn't fetch it, so the phone gets the original address to try itself.
      imageUrl: `${imageBase}/missing.jpg`,
      caption: "Scotiabank Arena",
    });
    assert.ok(phone.log.some((e) => typeof e === "string" && e.startsWith("<audio")));
  });

  test("back-to-back whispers are spoken one after the other, never interleaved", async () => {
    brain.reply = () => [
      { type: "whisper", id: "a", text: "first", reason: "reply", cover_blown_risk: null },
      { type: "whisper", id: "b", text: "second", reason: "task_done", cover_blown_risk: null },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "go", speaker: "them" });
    await until(() => phone.events("whisper_audio_end").length === 2);

    const audioEvents = phone.log
      .map((e) => (typeof e === "string" ? "audio" : e.type.startsWith("whisper_audio") ? `${e.type}:${e.id}` : null))
      .filter(Boolean);
    assert.deepEqual(audioEvents, [
      "whisper_audio_start:a",
      "audio",
      "whisper_audio_end:a",
      "whisper_audio_start:b",
      "audio",
      "whisper_audio_end:b",
    ]);
  });
});

describe("photo relay", () => {
  const photoDone = (imageUrl: string) => ({
    type: "task_done",
    task_id: "t1",
    task: "find_photo",
    ok: true,
    image_url: imageUrl,
    title: "Drake at Scotiabank Arena",
  });

  test("the phone gets the photo from the gateway's /media, not the original host", async () => {
    brain.reply = () => [photoDone(`${imageBase}/photo.jpg`)];
    const phone = new FakePhone();
    phones.push(phone);
    new PhoneSession(phone as never, "https://whispr.example");
    phone.say({ type: "debug_turn", text: "I went to Drake's concert last night", speaker: "me" });
    await until(() => phone.events("task_done").length === 1);

    const { imageUrl } = phone.events("task_done")[0];
    const match = /^https:\/\/whispr\.example\/media\/([0-9a-f-]{36})$/.exec(imageUrl);
    assert.ok(match, `unexpected imageUrl ${imageUrl}`);
    const image = getImage(match[1]);
    assert.equal(image?.contentType, "image/jpeg");
    assert.deepEqual(image?.body, PHOTO);
  });

  test("the photo-ready whisper never overtakes a photo that's still downloading", async () => {
    brain.reply = () => [
      photoDone(`${imageBase}/photo.jpg?delay=300`),
      { type: "whisper", id: "ready", text: "Photo's on your phone.", reason: "task_done", cover_blown_risk: null },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "prove it", speaker: "them" });
    await until(() => phone.events("whisper").length === 1);

    const order = phone.log.filter((e) => typeof e !== "string" && ["task_done", "whisper"].includes(e.type));
    assert.deepEqual(
      order.map((e) => (e as Record<string, any>).type),
      ["task_done", "whisper"],
    );
  });
});

describe("photo-ready alert", () => {
  test("is tagged photo_ready so the app keeps the line on screen, and is still spoken", async () => {
    brain.reply = () => [
      { type: "whisper", id: "line", text: "Say hold on, let me find it.", reason: "reply", cover_blown_risk: null },
      { type: "whisper", id: "ready", text: "The photo's in your camera roll. Show them now.", reason: "task_done", cover_blown_risk: null },
    ];
    const { phone } = newSession();
    phone.say({ type: "debug_turn", text: "prove it", speaker: "them" });
    await until(() => phone.events("whisper_audio_end").length === 2);

    assert.deepEqual(
      phone.events("whisper").map((e) => [e.id, e.reason]),
      [
        ["line", "reply"],
        ["ready", "photo_ready"],
      ],
    );
    assert.deepEqual(
      phone.events("whisper_audio_end").map((e) => e.id),
      ["line", "ready"],
    );
  });
});

/** Plays `pcm` into a session as if the phone sent it and Scribe committed it as one line. */
function speakInto(session: unknown, text: string, pcm: Buffer) {
  const scribe = (session as any).scribe;
  const start: number = scribe.sentSeconds;
  const seconds = pcm.length / 32000;
  scribe.sent.push({ start, end: start + seconds, db: levelDb(pcm), pcm });
  scribe.sentSeconds += seconds;
  scribe.emit("committed", text, { levelDb: levelDb(pcm), words: [{ text, start, end: start + seconds }] });
}

function voiceSession(deviceId?: string) {
  const phone = new FakePhone();
  phones.push(phone);
  const session = new PhoneSession(phone as never);
  if (deviceId) phone.say({ type: "hello", device: "test", sampleRate: 16000, deviceId });
  return { phone, session };
}

describe("calibration", () => {
  test("listens across lines until it has ~4 s of the wearer's speech, reporting progress", async () => {
    brain.reply = () => [];
    const { phone, session } = voiceSession();
    phone.say({ type: "calibrate", who: "me" });
    speakInto(session, "hey there", speak(ALEX, 2, 1));
    assert.equal(phone.events("calibrated").length, 0, "one short line isn't enough");
    speakInto(session, "I'm Alex, nice to meet you", speak(ALEX, 4.2, 2));

    const progress = phone.events("calibrating");
    assert.equal(progress.length, 2);
    assert.ok(progress[0].seconds < 4 && progress[1].seconds >= 4, `progress ${progress.map((p) => p.seconds)}`);
    assert.equal(progress[1].target, 4);
    assert.deepEqual(phone.events("calibrated")[0], { type: "calibrated", who: "me", ok: true });
    assert.ok(phone.events("transcript").every((t) => t.speaker === "me"));
  });

  test("their sample skips lines in the wearer's voice, then both voices are told apart", async () => {
    brain.reply = () => [];
    const { phone, session } = voiceSession();
    phone.say({ type: "calibrate", who: "me" });
    speakInto(session, "hey, I'm Alex", speak(ALEX, 5.6, 3));
    phone.say({ type: "calibrate", who: "them" });
    speakInto(session, "go on, say something", speak(ALEX, 2, 4)); // the wearer, prompting
    speakInto(session, "hi, I'm Kim, what's up", speak(KIM, 4.2, 5));
    assert.deepEqual(phone.events("calibrated").map((e) => [e.who, e.ok]), [
      ["me", true],
      ["them", true],
    ]);

    speakInto(session, "so did you see the show?", speak(KIM, 2.5, 6));
    speakInto(session, "yeah, it was great", speak(ALEX, 2.5, 7));
    // Earlier tests' lines can still be landing at the brain, so pick out this test's.
    const lines = ["hey, I'm Alex", "go on, say something", "hi, I'm Kim, what's up", "so did you see the show?", "yeah, it was great"];
    const heard = () => brain.received.filter((m) => lines.includes(m.text as string));
    await until(() => heard().length === lines.length);
    assert.deepEqual(
      heard().map((m) => [m.text, m.speaker]),
      [
        ["hey, I'm Alex", "me"],
        ["go on, say something", "me"],
        ["hi, I'm Kim, what's up", "them"],
        ["so did you see the show?", "them"],
        ["yeah, it was great", "me"],
      ],
    );
  });

  test("gives up after 4 lines without enough speech", async () => {
    const { phone, session } = voiceSession();
    phone.say({ type: "calibrate", who: "them" });
    for (let i = 0; i < 4; i++) speakInto(session, "mm", Buffer.alloc(3200));
    assert.deepEqual(phone.events("calibrated")[0], { type: "calibrated", who: "them", ok: false, reason: "too_short" });
  });

  test("refuses a sample of the other person that's really the wearer", async () => {
    brain.reply = () => [];
    const { phone, session } = voiceSession();
    phone.say({ type: "calibrate", who: "me" });
    speakInto(session, "hey, I'm Alex", speak(ALEX, 5.6, 9));
    phone.say({ type: "calibrate", who: "them" });
    // Nobody else speaks up: the wearer keeps talking past the two skipped lines.
    for (let i = 0; i < 3; i++) speakInto(session, `come on, say something ${i}`, speak(ALEX, 4.2, 10 + i));
    assert.deepEqual(phone.events("calibrated").at(-1), {
      type: "calibrated",
      who: "them",
      ok: false,
      reason: "sounds_like_you",
    });
  });

  test("a reconnecting phone keeps its calibration", async () => {
    brain.reply = () => [];
    const first = voiceSession("phone-1");
    first.phone.say({ type: "calibrate", who: "me" });
    speakInto(first.session, "hey, I'm Alex", speak(ALEX, 5.6, 8));
    first.phone.emit("close");

    const again = voiceSession("phone-1");
    assert.deepEqual(again.phone.events("calibrated"), [{ type: "calibrated", who: "me", ok: true }]);
    const other = voiceSession("phone-2");
    assert.equal(other.phone.events("calibrated").length, 0);
  });
});

